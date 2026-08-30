#!/usr/bin/env python3
"""Generate a throwaway CA plus a localhost server cert for the TLS spike.

Stands in for a Cloudflare Origin CA certificate: same shape (a leaf signed by
a CA the peer is configured to trust), so it exercises the same code path in
the server. Also emits a client cert, which is what Authenticated Origin Pulls
requires the origin to verify.

Deleted at M1 along with the rest of spikes/.
"""

import datetime
import ipaddress
import pathlib

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import NameOID

OUT = pathlib.Path(__file__).parent / "cert"
OUT.mkdir(exist_ok=True)

now = datetime.datetime.now(datetime.timezone.utc)
NOT_BEFORE = now - datetime.timedelta(days=1)
NOT_AFTER = now + datetime.timedelta(days=3650)


def name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def write(path, data):
    p = OUT / path
    p.write_bytes(data)
    print(f"  {p.relative_to(OUT.parent)}  ({len(data)} bytes)")


def pem_key(key):
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def make_ca(label, key):
    cert = (
        x509.CertificateBuilder()
        .subject_name(name(f"doot spike {label} CA"))
        .issuer_name(name(f"doot spike {label} CA"))
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOT_BEFORE)
        .not_valid_after(NOT_AFTER)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    return cert


def make_leaf(label, ca_cert, ca_key, key, cn, server=True):
    san = [x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
    usage = (
        x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH])
        if server
        else x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.CLIENT_AUTH])
    )
    builder = (
        x509.CertificateBuilder()
        .subject_name(name(cn))
        .issuer_name(ca_cert.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOT_BEFORE)
        .not_valid_after(NOT_AFTER)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(usage, critical=False)
    )
    if server:
        builder = builder.add_extension(x509.SubjectAlternativeName(san), critical=False)
    return builder.sign(ca_key, hashes.SHA256())


def emit(label, keygen):
    print(f"{label}:")
    ca_key = keygen()
    ca_cert = make_ca(label, ca_key)
    write(f"ca_{label}.crt", ca_cert.public_bytes(serialization.Encoding.PEM))
    write(f"ca_{label}.key", pem_key(ca_key))

    srv_key = keygen()
    srv = make_leaf(label, ca_cert, ca_key, srv_key, "localhost", server=True)
    # Leaf first, then issuer: the order a TLS server must send.
    write(
        f"server_{label}.crt",
        srv.public_bytes(serialization.Encoding.PEM)
        + ca_cert.public_bytes(serialization.Encoding.PEM),
    )
    write(f"server_{label}.key", pem_key(srv_key))

    cli_key = keygen()
    cli = make_leaf(label, ca_cert, ca_key, cli_key, "doot-spike-client", server=False)
    write(f"client_{label}.crt", cli.public_bytes(serialization.Encoding.PEM))
    write(f"client_{label}.key", pem_key(cli_key))


emit("ec", lambda: ec.generate_private_key(ec.SECP256R1()))
emit("rsa", lambda: rsa.generate_private_key(public_exponent=65537, key_size=2048))
print("done")
