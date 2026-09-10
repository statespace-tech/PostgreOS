# Security Policy

PostgreOS is an early prototype. Do not use it for sensitive or production data.

Do not report a suspected vulnerability in a public issue. Use
[GitHub private vulnerability reporting](https://github.com/statespace-tech/PostgreOS/security/advisories/new).
Include the affected revision, impact, reproduction steps, and proposed mitigation, if
you have one.

The project does not yet provide multi-tenant isolation. Use a dedicated test database
and a role that cannot access unrelated databases.
