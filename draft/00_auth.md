Good set of questions — these are actually four distinct layers in Splunk. Let me take them in order.

## 1. How Splunk Authentication Works (the big picture)

Splunk has two completely separate authentication worlds:

**Human/user authentication** (Web UI on 8000, REST on 8089) — evaluated in this order:
1. **Native (local) authentication** — accounts stored on that instance
2. **External authentication** — LDAP/AD, SAML, or OIDC, if configured
3. **Scripted authentication** — a custom script bridging to PAM, RADIUS, etc. (legacy escape hatch)

Plus **token-based auth**: JWT bearer tokens for REST API calls (automation, scripts) so you don't embed passwords, with their own expiry and audience settings.

**Machine-to-machine authentication** (node ↔ node) — entirely separate from user accounts:
- `pass4SymmKey` shared secrets for cluster manager ↔ peers and SHC members
- TLS certificates for forwarder → indexer and inter-node traffic
- This is why "my cluster works" and "users can't log in" are unrelated problems

The flow for a login: credentials hit splunkd → splunkd checks which auth scheme is active (`authentication.conf`) → validates locally or against the external provider → maps the user to one or more **roles** → the role set determines every capability and index they can touch. Authentication answers "who are you"; roles answer everything else.

## 2. Does Each System Have Its Own Local Accounts?

**Yes — and this surprises people.** Local (native) accounts live in `$SPLUNK_HOME/etc/passwd` on *each individual instance*. There is no built-in synchronization of local accounts across a deployment:

| Component | Local account behavior |
|---|---|
| Standalone SH / indexer | Own local accounts |
| Search Head Cluster | Some knowledge objects replicate, and user config can replicate via the deployer/conf replication — but treat local accounts as per-member and fragile |
| Indexer cluster peers | Each peer has its own local accounts (rarely logged into directly) |
| Cluster Manager, Deployer, License Manager | Each has its own |

So if you create `jsmith` on the search head, `jsmith` does not exist on the cluster manager. In practice the sane pattern is:

- **Humans:** authenticate centrally via LDAP/SAML/OIDC — identity lives in AD/Okta/Entra, not in Splunk
- **Local accounts:** kept only as **break-glass admin** on each node (for when the IdP is down or you're on the CLI fixing exactly the kind of problem from your last question — CLI commands like `splunk show cluster-status -auth` authenticate against *that node's* local accounts or configured auth)
- **Automation:** JWT tokens or dedicated service accounts, not shared admin passwords

## 3. Does Splunk Support SAML or OIDC?

**Both — with a version caveat.**

**SAML:** supported for years and the most common enterprise setup. Splunk Web acts as the Service Provider; your IdP (Okta, Entra ID/Azure AD, Ping, ADFS) does the login, MFA, conditional access. Splunk consumes the SAML assertion and — critically — reads a **group attribute** from the assertion to map users to Splunk roles. Configured under Settings → Authentication Methods, or `authentication.conf`.

**OIDC:** natively supported in Splunk Enterprise from **version 9.1+** and in Splunk Cloud. Same idea as your GitHub/AWS work from earlier — Splunk acts as the relying party, redirects to the IdP, receives an ID token (JWT), validates it against the IdP's JWKS, and maps claims to roles. If you're on 8.x or 9.0, you don't have native OIDC; SAML is your path.

Two operational notes: when SAML/OIDC is enabled, local accounts can still work as fallback (configurable — keep at least one break-glass admin), and the REST API/CLI generally doesn't do the browser redirect dance, which is exactly why tokens exist for programmatic access.

## 4. Roles — and Specifically "Who Can Query Which Index"

Splunk authorization is **role-based** (`authorize.conf`). A user gets one or more roles; a role is a bundle of three things:

1. **Capabilities** — atomic permissions (`search`, `schedule_search`, `edit_user`, `accelerate_datamodel`, ~100+ of them)
2. **Index access** — the part you asked about:
   - `srchIndexesAllowed` — indexes the role *may* search (supports wildcards like `app_*`)
   - `srchIndexesDefault` — indexes searched when the user doesn't specify `index=`
3. **Constraints/quotas** — `srchFilter` (a search-time filter silently ANDed onto every query — e.g., `host=web*` or `NOT sourcetype=pci`), `srchTimeWin` (max time range), `srchJobsQuota`, `srchDiskQuota`

**Built-in roles:**

| Role | Rough meaning |
|---|---|
| `admin` | Everything (on-prem full control) |
| `sc_admin` | Splunk Cloud's admin equivalent |
| `power` | Search + share objects, schedule searches, some editing |
| `user` | Basic search on permitted indexes, private objects only |
| `can_delete` | Holds the `delete_by_keyword` capability — assign temporarily, never permanently |

**Roles support inheritance** — a custom role can inherit from `user` and add index access, which is the standard pattern.

**The concrete recipe for "let this team query index X":**

```ini
# authorize.conf (or Settings → Roles in the UI)
[role_secops_analyst]
importRoles = user
srchIndexesAllowed = security;firewall;proxy
srchIndexesDefault = security
srchTimeWin = 2592000          # optional: cap at 30 days
srchFilter =                    # optional row-level filter
```

Then connect identity to role — this is where sections 1–3 meet:

- **LDAP:** map an AD group → `role_secops_analyst` in the LDAP strategy config
- **SAML:** map the group name arriving in the assertion's group attribute → role (Settings → Authentication Methods → SAML Groups)
- **OIDC:** map a groups claim from the ID token → role
- **Local:** assign the role directly on the user

So the end-to-end story for one analyst: *Okta authenticates her (SAML/OIDC) → the assertion carries group `SecOps-Analysts` → Splunk maps that group to `role_secops_analyst` → that role allows `index=security` and friends → any search she runs outside those indexes returns nothing (not an error — Splunk silently scopes to allowed indexes).*

That "silently returns nothing" behavior is worth remembering: the single most common "Splunk is missing data!" ticket is actually a user whose role doesn't include the index — first thing to check is their effective roles (`Settings → Users` or `| rest /services/authentication/users`).

One layer beyond roles, for completeness: in ES or multi-tenant setups you'll also see app-level permissions and knowledge-object sharing controls, but index visibility is decided by exactly the role machinery above. Want a worked example of the SAML group-mapping config against Entra ID or Okta specifically, since that's the piece with the most vendor-specific gotchas?
