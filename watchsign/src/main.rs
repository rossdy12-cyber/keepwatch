//! watchsign: signs an Apple Watch app with a free Apple ID.
//!
//! isideload signs iPhone apps; Watch apps need the Watch registered as a *watchOS* development device and
//! *watchOS* provisioning profiles. This tool follows isideload's own sign flow (Sideloader::sign_app) but asks
//! Apple for watchOS profiles, and registers the Watch's UDID (which no sideloading tool does).
//!
//! Usage: watchsign <apple-id> <JarvisWatch.ipa or .app> <watch-udid> [output-folder]
//! The password is asked for (not shown); a 2FA code is asked for if Apple sends one.

use std::{
    env,
    io::{self, Write},
    path::{Path, PathBuf},
};

use apple_codesign_quick::ProvisioningProfile;
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        app_ids::{AppIdsApi, Profile},
        certificates::DevelopmentCertificate,
        developer_session::{DeveloperDeviceType, DeveloperSession},
        teams::TeamsApi,
    },
    sideload::{
        application::Application,
        builder::{ExtensionsBehavior, MaxCertsBehavior},
        cert_identity::CertificateIdentity,
        sign,
    },
    util::keyring_storage::KeyringStorage,
};
use rootcause::prelude::*;

const MACHINE_NAME: &str = "watchsign";

fn ask(prompt: &str) -> String {
    print!("{prompt}");
    io::stdout().flush().ok();
    let mut line = String::new();
    io::stdin().read_line(&mut line).ok();
    line.trim().to_string()
}

fn copy_dir(from: &Path, to: &Path) -> io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

/// Registers a device through Apple's newer v1 API. The old QH65B2 API has no watchos/ path, but the v1 API
/// registers Apple Watches as IOS-platform devices (identified by their UDID), which is what Xcode does. Uses
/// the session watchsign already authenticated (anisette headers + GrandSlam client), so no extra sign-in.
async fn register_device_v1(dev: &mut DeveloperSession, team_id: &str, name: &str, udid: &str) -> Result<(), Report> {
    // Try the plain App Store Connect shape first, then the developerservices2 variant with teamId.
    let bodies = [
        format!(r#"{{"data":{{"type":"devices","attributes":{{"name":"{name}","platform":"IOS","udid":"{udid}"}}}}}}"#),
        format!(r#"{{"data":{{"type":"devices","attributes":{{"name":"{name}","platform":"IOS","udid":"{udid}","teamId":"{team_id}"}}}}}}"#),
    ];
    let mut last = String::new();
    for body in bodies {
        let headers = dev.get_headers().await.context("Couldn't get Apple auth headers")?;
        let response = dev
            .get_grandslam_client()
            .post("https://developerservices2.apple.com/services/v1/devices?clientId=XABBG36SBA")?
            .headers(headers)
            .header("Content-Type", "application/vnd.api+json")
            .header("Accept", "application/vnd.api+json")
            .body(body)
            .send()
            .await
            .context("The v1 device-registration request failed")?;
        let status = response.status();
        let resp_headers = response.headers().clone();
        let bytes = response.bytes().await.unwrap_or_default();
        let text = String::from_utf8_lossy(&bytes).into_owned();
        let lower = text.to_lowercase();
        // Success, or "already registered" — either is fine.
        if status.is_success() || status.as_u16() == 409 || lower.contains("already") || lower.contains("duplicate") {
            return Ok(());
        }
        let hint = resp_headers
            .iter()
            .filter(|(k, _)| {
                let k = k.as_str().to_ascii_lowercase();
                k.contains("error") || k.contains("status") || k == "content-type" || k.contains("reason")
            })
            .map(|(k, v)| format!("{}={}", k, v.to_str().unwrap_or("?")))
            .collect::<Vec<_>>()
            .join(", ");
        last = format!(
            "HTTP {status} | body: {} | headers: {}",
            if text.is_empty() { "<empty>".to_string() } else { text },
            if hint.is_empty() { "<none>".to_string() } else { hint }
        );
    }
    bail!("Apple rejected the Watch registration.\n  {last}");
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("\nwatchsign failed:\n{error:?}");
        ask("\nPress Enter to close.");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Report> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| report!("Couldn't set up encryption"))?;
    isideload::init().map_err(|_| report!("Couldn't set up error reporting"))?;
    // INFO progress on the console; a detailed DEBUG log in watchsign.log to send me if something stalls.
    match std::fs::File::create("watchsign.log") {
        Ok(file) => tracing_subscriber::fmt()
            .with_max_level(tracing::Level::DEBUG)
            .with_ansi(false)
            .with_writer(std::sync::Mutex::new(file))
            .init(),
        Err(_) => tracing_subscriber::fmt().with_max_level(tracing::Level::INFO).with_target(false).init(),
    }

    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        println!("Usage: watchsign <apple-id> <JarvisWatch.ipa or .app> <watch-udid> [output-folder]");
        println!("Get the Watch's UDID from watch_probe.py (00008310-...).");
        return Ok(());
    }
    let apple_id = args[1].clone();
    let app_path = PathBuf::from(&args[2]);
    let watch_udid = args[3].clone();
    let out_dir = PathBuf::from(args.get(4).cloned().unwrap_or_else(|| "signed".to_string()));

    let password = rpassword::prompt_password(format!("Password for {apple_id} (hidden): "))
        .map_err(|e| report!("Couldn't read the password: {e}"))?;

    // ---- Sign in (with 2FA), as Xcode does
    let two_factor = async |params: TwoFactorCallbackParams| {
        if params.unknown {
            println!("That 2FA method didn't work. Type d to get a code on your devices instead.");
        } else if params.sms {
            println!("Apple sent a code by text message.");
        } else {
            println!("Apple sent a code to your devices (iPhone / Mac).");
        }
        let code = ask("Enter the 6-digit code (or r to resend, d for devices): ");
        Ok(match code.as_str() {
            "d" => TwoFactorCallbackResponse::SendToDevices,
            "r" if !params.unknown => TwoFactorCallbackResponse::ResendCode,
            _ => {
                // Apple rate-limits sign-ins; this step can sit quietly for a minute or two while it retries.
                println!("Checking the code and finishing sign-in — this can take a minute or two, please wait…");
                io::stdout().flush().ok();
                TwoFactorCallbackResponse::SubmitCode(code)
            }
        })
    };
    println!("Signing in to Apple...");
    let mut account = AppleAccount::builder(&apple_id)
        .anisette_provider(RemoteV3AnisetteProvider::default()?.set_serial_number("2".to_string()))
        .login(&password, two_factor)
        .await
        .context("Signing in to Apple failed")?;
    println!("Signed in. Opening the developer account…");
    let mut dev = DeveloperSession::from_account(&mut account)
        .await
        .context("Couldn't open the free developer account")?;

    let team = dev
        .list_teams()
        .await?
        .into_iter()
        .next()
        .ok_or_else(|| report!("This Apple ID has no developer team. Sign in once at developer.apple.com and accept the agreement."))?;
    println!("Developer team: {} ({})", team.name.as_deref().unwrap_or("Personal Team"), team.team_id);

    // ---- Register the Watch via Apple's v1 API (the old QH65B2 API has no watchos/ path), so its UDID
    // lands in the team provisioning profile below.
    register_device_v1(&mut dev, &team.team_id, "Apple Watch", &watch_udid)
        .await
        .context("Couldn't register the Watch")?;
    println!("Watch {watch_udid} registered.");

    // ---- A development certificate (kept in Windows Credential Manager, so the same one is reused)
    let cert_prompt = async |certs: Vec<DevelopmentCertificate>| {
        println!("\nThis Apple ID already has the most certificates Apple allows. Revoke one to continue:");
        for (index, cert) in certs.iter().enumerate() {
            println!("  {}: {} ({})", index + 1,
                cert.name.as_deref().unwrap_or("certificate"),
                cert.machine_name.as_deref().unwrap_or("unknown machine"));
        }
        println!("Only revoke ones you don't need (revoking SideStore's would stop SideStore's apps until it refreshes).");
        let choice = ask("Number(s) to revoke, comma separated (Enter to cancel): ");
        let picked: Vec<String> = choice
            .split(',')
            .filter_map(|s| s.trim().parse::<usize>().ok())
            .filter(|n| *n >= 1 && *n <= certs.len())
            .map(|n| certs[n - 1].serial_number.clone().unwrap_or_default())
            .collect();
        Ok(if picked.is_empty() { None } else { Some(picked) })
    };
    let storage = KeyringStorage::new(MACHINE_NAME.to_string());
    let identity = CertificateIdentity::retrieve(
        MACHINE_NAME, &apple_id, &mut dev, &team, &storage, &MaxCertsBehavior::Prompt(cert_prompt),
    )
    .await
    .context("Couldn't get a development certificate")?;
    println!("Development certificate ready.");

    // ---- App IDs (the app and its complications), with the team ID added as free accounts require
    let mut app = Application::new(app_path).context("Couldn't open the Watch app")?;
    let main_bundle_id = app.main_bundle_id()?;
    let main_id = format!("{main_bundle_id}.{}", team.team_id);
    app.update_bundle_id(&main_bundle_id, &main_id)?;
    let app_ids = app
        .register_app_ids(&ExtensionsBehavior::RegisterAll, &mut dev, &team)
        .await
        .context("Couldn't register the app IDs")?;
    let main_app_id = app_ids
        .iter()
        .find(|id| id.identifier == main_id)
        .cloned()
        .ok_or_else(|| report!("Apple didn't return the app ID {main_id}"))?;
    println!("App IDs: {}", app_ids.iter().map(|id| id.identifier.as_str()).collect::<Vec<_>>().join(", "));

    // ---- watchOS provisioning profiles (these list the Watch)
    let main_profile = dev
        .download_team_provisioning_profile(&team, &main_app_id, DeveloperDeviceType::Ios)
        .await
        .context("Couldn't get the watchOS provisioning profile")?;
    let mut profiles: Vec<(String, Profile, plist::Dictionary)> = Vec::new();
    for id in app_ids.iter().filter(|id| id.identifier != main_id) {
        let profile = dev
            .download_team_provisioning_profile(&team, id, DeveloperDeviceType::Ios)
            .await
            .context(format!("Couldn't get the profile for {}", id.identifier))?;
        let entitlements = ProvisioningProfile::parse(profile.encoded_profile.as_ref())?.entitlements().clone();
        profiles.push((id.identifier.clone(), profile, entitlements));
    }
    println!("Profiles ready (expire {:?}).", main_profile.date_expire);

    // ---- Sign
    app.bundle.write_info()?;
    for ext in app.bundle.app_extensions_mut() {
        ext.write_info()?;
    }
    sign::sign(&mut app, &identity, &main_profile, &mut profiles, &None, &team,
               None::<fn(f32) -> std::future::Ready<()>>)
        .await
        .context("Signing failed")?;

    let name = app.bundle.bundle_dir.file_name().map(|n| n.to_owned()).unwrap_or_else(|| "Watch.app".into());
    let target = out_dir.join(name);
    if target.exists() {
        std::fs::remove_dir_all(&target).ok();
    }
    copy_dir(&app.bundle.bundle_dir, &target).map_err(|e| report!("Couldn't save the signed app: {e}"))?;
    println!("\nSigned app saved to: {}", target.display());
    println!("Next: python watch_install.py \"{}\"", target.display());
    println!("It works for 7 days; then run watchsign and watch_install.py again.");
    Ok(())
}
