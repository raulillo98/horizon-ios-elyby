
clear
bin/env python3
"""Apply Ely.by skin support to Horizon's Rust renderer.

Run from the repository root:
    python3 apply_elyby_skins.py
"""
from pathlib import Path
import sys

ROOT = Path.cwd()
SKINS = ROOT / "crates/horizon-client-render/src/skins.rs"
AUTH = ROOT / "crates/horizon-client-render/src/auth.rs"

if not SKINS.is_file() or not AUTH.is_file():
    sys.exit("ERROR: ejecuta este script desde la raíz de horizon-ios-elyby.")

skins = SKINS.read_text(encoding="utf-8")
auth = AUTH.read_text(encoding="utf-8")

uri_anchor = '''pub const TEXTURE_URIS: [&str; 2] = [
    "https://textures.minecraft.net/texture/{textureId}",
    "http://textures.minecraft.net/texture/{textureId}",
];
'''
uri_addition = uri_anchor + '''

/// Ely.by's skin system stores textures on ely.by (for example
/// `http://ely.by/storage/skins/...png`). Accept these URLs in profile properties.
pub const ELYBY_TEXTURE_URIS: [&str; 4] = [
    "https://ely.by/",
    "http://ely.by/",
    "https://skinsystem.ely.by/",
    "http://skinsystem.ely.by/",
];

/// Texture hosts accepted in Minecraft profile `textures` properties.
pub const ALL_TEXTURE_URIS: [&str; 6] = [
    TEXTURE_URIS[0],
    TEXTURE_URIS[1],
    ELYBY_TEXTURE_URIS[0],
    ELYBY_TEXTURE_URIS[1],
    ELYBY_TEXTURE_URIS[2],
    ELYBY_TEXTURE_URIS[3],
];
'''

changes = 0
if "pub const ALL_TEXTURE_URIS" not in skins:
    if skins.count(uri_anchor) != 1:
        sys.exit("ERROR: no encuentro exactamente una declaración TEXTURE_URIS conocida en skins.rs.")
    skins = skins.replace(uri_anchor, uri_addition, 1)
    changes += 1

old_profile = "unpack(&value, signature, &TEXTURE_URIS).skin"
new_profile = "unpack(&value, signature, &ALL_TEXTURE_URIS).skin"
if old_profile in skins:
    skins = skins.replace(old_profile, new_profile, 1)
    changes += 1
elif new_profile not in skins:
    sys.exit("ERROR: no encuentro la llamada de profile_skin_url esperada en skins.rs.")

old_nbt = "unpack(&value, Signature::Unsigned, &TEXTURE_URIS).skin"
new_nbt = "unpack(&value, Signature::Unsigned, &ALL_TEXTURE_URIS).skin"
if old_nbt in skins:
    skins = skins.replace(old_nbt, new_nbt, 1)
    changes += 1
elif new_nbt not in skins:
    sys.exit("ERROR: no encuentro la llamada de profile_skin_url_nbt esperada en skins.rs.")

old_own = '''pub fn own_textures(session: &AuthSession) -> Option<crate::skins::Textures> {
    if session.user_type == "elyby" {
        return None;
    }
'''
new_own = '''pub fn own_textures(session: &AuthSession) -> Option<crate::skins::Textures> {
    if session.user_type == "elyby" {
        // Ely.by exposes a Mojang-compatible GameProfile endpoint. Request
        // signed textures so the returned property has the usual Authlib shape.
        let url = format!(
            "https://skinsystem.ely.by/profile/{}?unsigned=false",
            session.name
        );
        let response = agent().get(&url).call().ok()?;
        if response.status() != 200 {
            return None;
        }
        let body = response.into_string().ok()?;
        let profile: serde_json::Value = serde_json::from_str(&body).ok()?;
        let (value, signature) = crate::skins::parse_profile(&profile).textures?;
        return Some(crate::skins::unpack(
            &value,
            signature,
            &crate::skins::ALL_TEXTURE_URIS,
        ));
    }
'''
if old_own in auth:
    auth = auth.replace(old_own, new_own, 1)
    changes += 1
elif new_own not in auth:
    sys.exit("ERROR: no encuentro el bloque own_textures esperado en auth.rs.")

if changes == 0:
    print("Los cambios de soporte Ely.by ya parecen estar aplicados. No se modificó nada.")
    sys.exit(0)

SKINS.write_text(skins, encoding="utf-8")
AUTH.write_text(auth, encoding="utf-8")
print(f"OK: cambios aplicados ({changes} sustituciones).")
print("Archivos modificados:")
print(f" - {SKINS.relative_to(ROOT)}")
print(f" - {AUTH.relative_to(ROOT)}")
print("Siguiente comprobación: cargo fmt --all -- --check")
print("Después: cargo check -p horizon-client-render")
