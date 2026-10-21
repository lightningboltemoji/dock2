# Makes the vectors the crypto tests check against — with Python's hashlib and hmac and openssl's AES,
# nothing of the crate's own. Run from this folder: python3 make.py
import base64, hashlib, hmac, os, subprocess

password, email = b"correct horse", b"someone@example.com"
master = hashlib.pbkdf2_hmac("sha256", password, email, 5000, 32)
open("master_key.hex", "w").write(master.hex())
open("hash.b64", "w").write(base64.b64encode(hashlib.pbkdf2_hmac("sha256", master, password, 1, 32)).decode())
# HKDF-Expand for one block: T(1) = HMAC(PRK, info || 0x01).
enc = hmac.new(master, b"enc\x01", hashlib.sha256).digest()
mac = hmac.new(master, b"mac\x01", hashlib.sha256).digest()
open("stretched.hex", "w").write((enc + mac).hex())

key = os.urandom(64)
iv = os.urandom(16)
plain = b"hunter2 is not a password"
ct = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", key[:32].hex(), "-iv", iv.hex()], input=plain, capture_output=True, check=True).stdout
tag = hmac.new(key[32:], iv + ct, hashlib.sha256).digest()
open("key.hex", "w").write(key.hex())
b64 = lambda b: base64.b64encode(b).decode()
open("sealed.txt", "w").write(f"2.{b64(iv)}|{b64(ct)}|{b64(tag)}")
print("vectors written")

# An organization: an RSA key in PKCS#8, sealed with the user key above; the organization's key encrypted
# to it with OAEP and SHA-1, as Bitwarden's type 4; an item's name sealed with the organization's key.
def seal(plain, k):
    iv = os.urandom(16)
    ct = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", k[:32].hex(), "-iv", iv.hex()], input=plain, capture_output=True, check=True).stdout
    tag = hmac.new(k[32:], iv + ct, hashlib.sha256).digest()
    return f"2.{b64(iv)}|{b64(ct)}|{b64(tag)}"

pem = subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"], capture_output=True, check=True).stdout
der = subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-outform", "DER"], input=pem, capture_output=True, check=True).stdout
public = subprocess.run(["openssl", "pkey", "-pubout"], input=pem, capture_output=True, check=True).stdout
open("org_public.pem", "wb").write(public)
org_key = os.urandom(64)
wrapped = subprocess.run(["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", "org_public.pem", "-pkeyopt", "rsa_padding_mode:oaep",
                          "-pkeyopt", "rsa_oaep_md:sha1"], input=org_key, capture_output=True, check=True).stdout
os.remove("org_public.pem")
open("org_private.txt", "w").write(seal(der, key))
open("org_key.txt", "w").write(f"4.{b64(wrapped)}")
open("org_item.txt", "w").write(seal(b"Shared login", org_key))
print("organization vectors written")
