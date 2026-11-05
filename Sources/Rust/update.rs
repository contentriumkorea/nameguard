use crate::core::*;
use crate::services::{bundle, run};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

const RELEASES: &str = "https://github.com/contentriumkorea/nameguard/releases";
const MAX_SIZE: u64 = 64 * 1024 * 1024;
#[derive(Clone, Debug)]
pub struct Release {
    pub version: String,
    pub url: String,
    pub size: u64,
    pub sha256: String,
}
pub fn version_numbers(value: &str) -> Result<[u32; 3]> {
    let parts: Vec<_> = value.split('.').collect();
    if !(2..=3).contains(&parts.len())
        || parts
            .iter()
            .any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(error("버전 정보를 확인할 수 없습니다."));
    }
    Ok([
        parts[0].parse()?,
        parts[1].parse()?,
        if parts.len() == 3 {
            parts[2].parse()?
        } else {
            0
        },
    ])
}
impl Release {
    pub fn parse(value: Value) -> Result<Self> {
        let tag = value["tag_name"]
            .as_str()
            .ok_or_else(|| error("새 버전 정보를 확인할 수 없습니다."))?;
        let version = tag.strip_prefix('v').ok_or_else(|| error("잘못된 버전"))?;
        version_numbers(version)?;
        if version.split('.').count() != 3
            || value["draft"] != false
            || value["prerelease"] != false
            || value["html_url"] != format!("{RELEASES}/tag/{tag}")
        {
            return Err(error("잘못된 업데이트 정보"));
        }
        let asset = value["assets"]
            .as_array()
            .and_then(|a| a.iter().find(|a| a["name"] == "NameGuard.zip"))
            .ok_or_else(|| error("업데이트 파일이 없습니다."))?;
        let url = format!("{RELEASES}/download/{tag}/NameGuard.zip");
        let size = asset["size"]
            .as_u64()
            .filter(|s| *s > 0 && *s <= MAX_SIZE)
            .ok_or_else(|| error("업데이트 파일 크기가 잘못되었습니다."))?;
        let hash = asset["digest"]
            .as_str()
            .and_then(|h| h.strip_prefix("sha256:"))
            .filter(|h| {
                h.len() == 64
                    && h.bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
            .ok_or_else(|| error("검증 가능한 업데이트 파일이 없습니다."))?;
        if asset["browser_download_url"] != url {
            return Err(error("업데이트 주소가 잘못되었습니다."));
        }
        Ok(Self {
            version: version.into(),
            url,
            size,
            sha256: hash.into(),
        })
    }
    pub fn validate(&self, data: &[u8]) -> Result<()> {
        if data.len() as u64 != self.size || format!("{:x}", Sha256::digest(data)) != self.sha256 {
            return Err(error(
                "다운로드한 파일 검증에 실패했습니다. 기존 앱은 유지됩니다.",
            ));
        }
        Ok(())
    }
}
fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(120))
        .build()
}
fn release_metadata(token: Option<&str>) -> Result<Release> {
    let client = agent();
    let mut request = client
        .get("https://api.github.com/repos/contentriumkorea/nameguard/releases/latest")
        .timeout(Duration::from_secs(20))
        .set("User-Agent", "NameGuard")
        .set("Accept", "application/vnd.github+json");
    if let Some(token) = token {
        request = request.set("Authorization", &format!("Bearer {token}"));
    }
    let response = request
        .call()
        .map_err(|_| error("새 버전을 확인하지 못했습니다. 인터넷 연결을 확인해 주세요."))?;
    let mut bytes = vec![];
    response
        .into_reader()
        .take(2 * 1024 * 1024)
        .read_to_end(&mut bytes)?;
    Release::parse(serde_json::from_slice(&bytes)?)
}
pub fn check() -> Result<Option<Release>> {
    // Production never reads credentials; CI supplies auth only to the test below.
    let release = release_metadata(None)?;
    Ok(
        (version_numbers(&release.version)? > version_numbers(env!("CARGO_PKG_VERSION"))?)
            .then_some(release),
    )
}
pub fn validate_entries(entries: &str) -> Result<()> {
    if entries.lines().count() == 0 {
        return Err(error("압축 파일이 비어 있습니다."));
    }
    for entry in entries.lines() {
        if !(entry.starts_with("NameGuard-Desktop/") || entry.starts_with("__MACOSX/"))
            || entry.contains('\\')
            || entry.split('/').any(|p| p == "..")
        {
            return Err(error("잘못된 업데이트 압축 파일입니다."));
        }
    }
    Ok(())
}
fn validate_links(path: &Path) -> Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            return Err(error("업데이트에 잘못된 링크가 있습니다."));
        }
        if kind.is_dir() {
            validate_links(&entry.path())?;
        }
    }
    Ok(())
}
pub struct Staged {
    pub workspace: PathBuf,
    pub candidate: PathBuf,
    pub token: String,
    pub target: PathBuf,
    pub version: String,
    pub directory: PathBuf,
}
impl Staged {
    pub fn cancel(&self) {
        let _ = fs::remove_dir_all(&self.candidate);
        let _ = fs::remove_dir_all(&self.workspace);
    }
    pub fn install(&self) -> Result<()> {
        let helper = self.workspace.join("install.sh");
        atomic(
            &helper,
            &fs::read(self.target.join("Contents/Resources/update.sh"))?,
        )?;
        let output = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(self.workspace.join("install.log"))?;
        Command::new("/bin/bash")
            .arg(helper)
            .arg(std::process::id().to_string())
            .arg(&self.target)
            .arg(&self.candidate)
            .arg(&self.workspace)
            .arg(&self.token)
            .arg(&self.version)
            .arg(&self.directory)
            .arg("300")
            .stdin(Stdio::null())
            .stdout(output.try_clone()?)
            .stderr(output)
            .spawn()?;
        Ok(())
    }
}
pub fn prepare(executable: &Path, directory: &Path, release: &Release) -> Result<Staged> {
    let target = bundle(executable).ok_or_else(|| error("먼저 설치.command로 설치해 주세요."))?;
    if physical(&target) != target
        || target.parent() != Some(home().join("Applications").as_path())
        || target.to_string_lossy().contains("/AppTranslocation/")
    {
        return Err(error(
            "먼저 설치.command로 사용자 응용프로그램 폴더에 설치해 주세요.",
        ));
    }
    let token = uuid::Uuid::new_v4().to_string();
    let workspace = directory.join("updates").join(&token);
    let candidate = PathBuf::from(format!("{}.nameguard-update-{token}.app", target.display()));
    let staged = Staged {
        workspace,
        candidate,
        token,
        target,
        version: release.version.clone(),
        directory: directory.to_owned(),
    };
    fs::create_dir_all(&staged.workspace)?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&staged.workspace, fs::Permissions::from_mode(0o700))?;
    let result = (|| -> Result<()> {
        let response = agent().get(&release.url).call()?;
        let mut data = vec![];
        response
            .into_reader()
            .take(release.size + 1)
            .read_to_end(&mut data)?;
        release.validate(&data)?;
        let zip = staged.workspace.join("update.zip");
        atomic(&zip, &data)?;
        validate_entries(&run("/usr/bin/unzip", &["-Z1", &zip.to_string_lossy()])?)?;
        let unpacked = staged.workspace.join("unpacked");
        run(
            "/usr/bin/ditto",
            &[
                "-x",
                "-k",
                &zip.to_string_lossy(),
                &unpacked.to_string_lossy(),
            ],
        )?;
        validate_links(&unpacked)?;
        let app = unpacked.join("NameGuard-Desktop/NameGuard Desktop.app");
        let info = plist::Value::from_file(app.join("Contents/Info.plist"))?;
        let dictionary = info.as_dictionary().ok_or_else(|| error("앱 정보 오류"))?;
        for (key, expected) in [
            ("CFBundleIdentifier", "local.nameguard.desktop.app"),
            ("CFBundleExecutable", "nameguard"),
            ("CFBundleShortVersionString", release.version.as_str()),
        ] {
            if dictionary.get(key).and_then(plist::Value::as_string) != Some(expected) {
                return Err(error("업데이트 앱의 정보가 다릅니다."));
            }
        }
        run(
            "/usr/bin/codesign",
            &["--verify", "--deep", "--strict", &app.to_string_lossy()],
        )?;
        run(
            "/usr/bin/ditto",
            &[&app.to_string_lossy(), &staged.candidate.to_string_lossy()],
        )?;
        let current = plist::Value::from_file(staged.target.join("Contents/Info.plist"))?;
        if current
            .as_dictionary()
            .and_then(|d| d.get("CFBundleIdentifier"))
            .and_then(plist::Value::as_string)
            == Some("local.nameguard.app")
        {
            run(
                "/usr/bin/plutil",
                &[
                    "-replace",
                    "CFBundleIdentifier",
                    "-string",
                    "local.nameguard.app",
                    &staged
                        .candidate
                        .join("Contents/Info.plist")
                        .to_string_lossy(),
                ],
            )?;
            run(
                "/usr/bin/codesign",
                &[
                    "--force",
                    "--sign",
                    "-",
                    "--identifier",
                    "local.nameguard.app",
                    &staged.candidate.to_string_lossy(),
                ],
            )?;
        }
        run(
            "/usr/bin/codesign",
            &[
                "--verify",
                "--deep",
                "--strict",
                &staged.candidate.to_string_lossy(),
            ],
        )?;
        Ok(())
    })();
    if let Err(e) = result {
        staged.cancel();
        return Err(e);
    }
    Ok(staged)
}
pub fn health_receipt(path: &Path, directory: &Path) -> Option<PathBuf> {
    let parent = path.parent()?;
    if path.file_name()? != "health"
        || uuid::Uuid::parse_str(parent.file_name()?.to_str()?).is_err()
        || physical(parent.parent()?) != physical(&directory.join("updates"))
    {
        return None;
    }
    Some(path.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn numeric_versions_reject_invalid() -> Result<()> {
        assert!(version_numbers("1.10.0")? > version_numbers("1.2")?);
        assert!(version_numbers("1.3-beta").is_err());
        Ok(())
    }
    #[test]
    fn release_digest_origin_and_archive_validation() -> Result<()> {
        let mut value = serde_json::json!({"tag_name":"v1.3.0","html_url":format!("{RELEASES}/tag/v1.3.0"),"draft":false,"prerelease":false,"assets":[{"name":"NameGuard.zip","browser_download_url":format!("{RELEASES}/download/v1.3.0/NameGuard.zip"),"size":3,"digest":format!("sha256:{:x}",Sha256::digest(b"abc"))}]});
        let release = Release::parse(value.clone())?;
        release.validate(b"abc")?;
        assert!(release.validate(b"abd").is_err());
        value["assets"][0]["browser_download_url"] = "https://example.com/evil.zip".into();
        assert!(Release::parse(value.clone()).is_err());
        value["prerelease"] = true.into();
        assert!(Release::parse(value).is_err());
        validate_entries("NameGuard-Desktop/NameGuard Desktop.app/Contents/Info.plist\n")?;
        validate_entries(&String::from_utf8_lossy(b"NameGuard-Desktop/\xeb\xb3?\n"))?;
        for entry in [
            "/tmp/evil",
            "NameGuard-Desktop/../../evil",
            "NameGuard-Desktop/a\\file",
            "Other.app/file",
        ] {
            assert!(validate_entries(entry).is_err());
        }
        Ok(())
    }
    #[test]
    fn health_cannot_escape_state() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let token = uuid::Uuid::new_v4().to_string();
        let receipt = temp.path().join("updates").join(token).join("health");
        fs::create_dir_all(receipt.parent().unwrap())?;
        assert!(health_receipt(&receipt, temp.path()).is_some());
        assert!(health_receipt(&temp.path().join("outside/health"), temp.path()).is_none());
        Ok(())
    }
    #[test]
    fn real_download_and_packaged_candidate_validation() -> Result<()> {
        let Ok(zip) = std::env::var("NAMEGUARD_TEST_ZIP") else {
            return Ok(());
        };
        use std::io::Write;
        let bytes = fs::read(&zip)?;
        let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
        let url = format!("http://{}/NameGuard.zip", listener.local_addr()?);
        let server = std::thread::spawn(move || {
            for _ in 0..2 {
                let (mut socket, _) = listener.accept().unwrap();
                let mut request = [0; 4096];
                let _ = socket.read(&mut request);
                write!(
                    socket,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    bytes.len()
                )
                .unwrap();
                socket.write_all(&bytes).unwrap();
            }
        });
        let temp = tempfile::tempdir()?;
        let directory = temp.path().join("state");
        let app = home().join("Applications").join(format!(
            "NameGuard Download Test {}.app",
            uuid::Uuid::new_v4()
        ));
        let cleanup = (|| -> Result<()> {
            let unpacked = temp.path().join("payload");
            run(
                "/usr/bin/ditto",
                &["-x", "-k", &zip, &unpacked.to_string_lossy()],
            )?;
            fs::create_dir_all(app.parent().unwrap())?;
            run(
                "/usr/bin/ditto",
                &[
                    &unpacked
                        .join("NameGuard-Desktop/NameGuard Desktop.app")
                        .to_string_lossy(),
                    &app.to_string_lossy(),
                ],
            )?;
            let release = Release {
                version: env!("CARGO_PKG_VERSION").into(),
                url,
                size: fs::metadata(&zip)?.len(),
                sha256: format!("{:x}", Sha256::digest(fs::read(&zip)?)),
            };
            let executable = app.join("Contents/MacOS/nameguard");
            let staged = prepare(&executable, &directory, &release)?;
            assert!(staged.candidate.join("Contents/MacOS/nameguard").exists());
            staged.cancel();
            let mut corrupt = release;
            corrupt.sha256 = "a".repeat(64);
            assert!(prepare(&executable, &directory, &corrupt).is_err());
            Ok(())
        })();
        let _ = fs::remove_dir_all(&app);
        cleanup?;
        server.join().unwrap();
        if let Ok(token) = std::env::var("GH_TOKEN") {
            let _ = release_metadata(Some(&token))?;
        }
        Ok(())
    }
}
