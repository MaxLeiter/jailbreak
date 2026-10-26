# ca-certificates

Procursus's `cacerts.mk` bundle, rebuilt from a newer Mozilla extract. Same files and
symlinks as the Procursus package (`etc/ssl/certs/cacert.pem`, `etc/ssl/cert.pem`,
`usr/lib/ssl/{cacert.pem,certs}`, `etc/profile.d/cacerts.bootstrap.sh`), so OpenSSL,
GnuTLS (glib-networking, WebKitGTK), curl and apt all read it.

Shipped as `20261020+ios1` for the eMudhra key compromise (October 2026): Procursus's
`20240604` still trusts `emSign ECC Root CA - G3` and `Comodo AAA Services root`, which
signed and cross-signed the compromised intermediates, and none of these clients check
revocation. The `+ios1` sorts above a Procursus rebuild of the same bundle date, and any
later Procursus bundle (a later date) replaces this one.

Unlike Procursus, `cacert.pem` is not a conffile: a security update to the bundle must
replace it even on a device where it was edited.

Refresh:

```sh
d=2026-10-20   # date of the extract at https://curl.se/ca/
curl -fLO https://curl.se/ca/cacert-$d.pem
curl -fL https://curl.se/ca/cacert-$d.pem.sha256   # must match shasum -a 256
cp cacert-$d.pem x11/packages/ca-certificates/var/jb/etc/ssl/certs/cacert.pem
# bump Version in DEBIAN/control (YYYYMMDD+ios1), then:
bash x11/packages/ca-certificates/build.sh
```
