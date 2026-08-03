# SIRK Updater TLS validation

Production SIRK Updater uses the operating-system certificate trust store and validates both the server certificate chain and the requested host name.

Rules:

- remote health URLs must use HTTPS;
- plaintext HTTP is accepted only for `localhost` and IP loopback addresses used by a locally installed product service;
- production code must not set `ServerCertificateCustomValidationCallback` or use `DangerousAcceptAnyServerCertificateValidator`;
- tests may inject an explicit HTTP message handler without changing production defaults;
- CI contains a permanent contract preventing a certificate-validation bypass from being reintroduced.
