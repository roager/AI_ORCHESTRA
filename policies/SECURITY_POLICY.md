# SECURITY_POLICY

**Version:** 0.1
**Status:** Initial governance rules
**Authority:** Subordinate to `docs\AI_ORCHESTRA_GUIDELINES.md`.

This document defines the core security practices and restrictions for the AI_ORCHESTRA project.

---

## 1. Credential & Secret Management

1. **No Secrets in Artifacts:** Task files (`TASK.json`), reports (`WORKER_REPORT.json`, `REVIEW.json`), and log files must never contain secrets, passwords, or API keys.
2. **No Raw GitHub Tokens:** Under no circumstances should raw GitHub tokens, SSH keys, or personal access tokens be written into prompts, source code files, or configuration files.
3. **Host-Managed Credentials Only:** Authentication must rely on the host system configuration (e.g., Git Credential Manager, OS environment variables, local SSH agent).
4. **Sensitive File Handling:** `.env`, `.pem`, key files, and credential stores must be treated as sensitive and must never be committed or processed by AI models without explicit restriction.

---

## 2. Scope & Privilege Management

1. **CI/CD Changes Restricted:** Any modification to CI/CD workflows, GitHub Actions (`.github/workflows`), or build pipeline configurations requires explicit task authorization.
2. **No Silent Privilege Escalation:** Any attempt by an agent to widen its access, modify protected files, or run unauthorized commands will trigger an immediate halt and transition the run to `HUMAN_REQUIRED`.
3. **Worker Privileges Bounded:** Worker agents do not inherit publication privileges. A worker can never push or publish code changes directly.
