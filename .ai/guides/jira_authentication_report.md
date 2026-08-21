# JIRA & Confluence Authentication Architecture Report

This report provides a detailed technical breakdown of how the JIRA and Confluence CLI applications handle authentication. This architecture allows developers to build CLI tools that seamlessly integrate with Atlassian Cloud APIs using both standard API token credentials and dynamic, zero-config browser session cookie extraction.

---

## 1. Authentication Schemes

The application supports two distinct authentication methods:

### A. API Token / Basic Authentication
This is the standard Atlassian Cloud REST API authentication scheme.
* **Mechanism:** HTTP Basic Authentication.
* **Format:** `Basic <Base64(email:api_token)>`.
* **Headers:**
  ```http
  Authorization: Basic <Base64 encoded string>
  ```
* **Use Case:** Headless environments, CI/CD pipelines, or users who prefer standard API keys. Atlassian API tokens are generated via the Atlassian Account console.

### B. Browser Session Cookie Authentication
This is a highly user-friendly scheme that allows the CLI to authenticate using the user's active browser session.
* **Mechanism:** Passing active session cookies extracted from the local web browser directly to Atlassian APIs.
* **Headers:**
  ```http
  Cookie: <Full cookie string extracted from browser>
  X-Atlassian-Token: no-check
  ```
* **Anti-CSRF Protection:** Atlassian APIs require the presence of the `X-Atlassian-Token: no-check` header when authenticating via cookies to prevent Cross-Site Request Forgery (CSRF) attacks. Without this header, cookie-authenticated API requests will fail.

---

## 2. Dynamic Browser Cookie Extraction (`rookie` Crate)

One of the most powerful features of this codebase is the ability to automatically extract JIRA/Confluence cookies from the local user's web browsers (Chrome or Firefox). This means if the user is already logged in to Atlassian on their machine, the CLI can run with **zero initial configuration**.

### How it Works
1. The CLI queries the browser's local database for cookies matching `<domain>.atlassian.net`.
2. It uses the `rookie` crate, which handles decrypting Chrome and Firefox cookie stores across different platforms (Linux, macOS, Windows).
3. The extracted cookies are formatted into a single cookie string (`name1=val1; name2=val2; ...`).

### Rust Implementation Detail (`src/api.rs`)
```rust
pub async fn fetch_jira_cookies(domain: &str) -> anyhow::Result<String> {
    let domains = Some(vec![format!("{}.atlassian.net", domain)]);
    
    // Try Chrome first, fallback to Firefox
    let cookies = if let Ok(c) = rookie::chrome(domains.clone()) {
        c
    } else if let Ok(c) = rookie::firefox(domains) {
        c
    } else {
        anyhow::bail!("Could not find Jira cookies in Chrome or Firefox. Are you logged in in your browser?");
    };

    let cookie_str = cookies.iter()
        .map(|c| format!("{}={}", c.name, c.value))
        .collect::<Vec<_>>()
        .join("; ");

    if cookie_str.is_empty() {
        anyhow::bail!("No Jira cookies found for {}.atlassian.net. Please log in in your browser.", domain);
    }

    Ok(cookie_str)
}
```

---

## 3. Configuration Loading & Precedence

The CLI manages authentication configurations by resolving environment variables and local `.rc` config files.

### A. Configuration Storage
Configurations are stored in standard `.env` style key-value files named `.jirarc` or `.confluencerc`.
1. **Precedence:** 
   * **Local Workspace:** First, checks for `.jirarc` / `.confluencerc` in the current working directory.
   * **System Configuration Directory:** Falls back to OS-specific configuration directories (e.g., `~/.config/jira-cli/config` or `~/.config/confluence-cli/config`).
2. **Loading:** The `dotenvy` crate is used to load the determined configuration file directly into the process environment variables during startup:
   ```rust
   let config_path = get_config_path(force_local);
   if config_path.exists() {
       dotenvy::from_path(&config_path).ok();
   }
   ```

### B. Environment Variables Used
* **JIRA / Confluence Domain:** `JIRA_DOMAIN` / `CONFLUENCE_DOMAIN`
* **User Email:** `JIRA_EMAIL` / `CONFLUENCE_EMAIL`
* **API Token:** `JIRA_API_TOKEN` / `CONFLUENCE_API_TOKEN`
* **Session Cookie:** `JIRA_COOKIE` / `CONFLUENCE_COOKIE`

### C. Resolution Flow and Fallback Logic
When a command is executed, the client goes through this resolution hierarchy to instantiate the client:

```
  [1] Resolve Domain
      ├── Try --domain CLI flag
      ├── Try CONFLUENCE_DOMAIN / JIRA_DOMAIN from environment (loaded from config rc)
      └── Fail if none found

  [2] Resolve Credentials
      ├── Case A: Session Cookie Found (CONFLUENCE_COOKIE or JIRA_COOKIE)
      │   └── Use Cookie-based Auth
      ├── Case B: Email & API Token Found (JIRA_EMAIL & JIRA_API_TOKEN)
      │   └── Use Basic Auth (Email + Token)
      └── Case C: No Credentials Found
          └── Fallback: Trigger silent dynamic browser cookie extraction (fetch_jira_cookies)
              ├── If cookies found -> Use Cookie-based Auth
              └── If cookies fail -> Fail and prompt user to login/configure
```

Here is the exact Rust implementation of the fallback logic in `src/main.rs`:
```rust
    let domain = cli.domain.clone().ok_or_else(|| anyhow::anyhow!("JIRA_DOMAIN must be set. Run 'jira-cli init' or use --domain flag."))?;
    let email = env::var("JIRA_EMAIL").ok();
    let api_token = env::var("JIRA_API_TOKEN").ok();
    let mut cookie = env::var("JIRA_COOKIE").ok();

    if cookie.is_none() && (email.is_none() || api_token.is_none()) {
        // Fallback: Try auto-fetching if no credentials at all
        if let Ok(fetched) = api::fetch_jira_cookies(&domain).await {
            cookie = Some(fetched);
        } else if !matches!(cli.command, Commands::Auth) {
            anyhow::bail!("No credentials found. Run 'jira-cli auth' to login via your browser or set JIRA_EMAIL and JIRA_API_TOKEN.");
        }
    }
```

---

## 4. Rebuilding Authentication Headers

Requests are signed with authentication headers dynamically before dispatching. Here is the request interceptor logic:

```rust
    fn add_auth_headers(&self, mut builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        if let Some(cookie) = &self.cookie {
            builder = builder.header(reqwest::header::COOKIE, cookie);
            builder = builder.header("X-Atlassian-Token", "no-check");
        } else if let (Some(email), Some(api_token)) = (&self.email, &self.api_token) {
            let auth = format!("{}:{}", email, api_token);
            builder = builder.header(AUTHORIZATION, format!("Basic {}", b64_encode(&auth)));
        }
        builder
    }
```

---

## 5. Replication Strategy for Other Languages

If you wish to replicate this authentication design in another project (e.g., in Node.js, Python, or Go), follow this recipe:

### 1. Browser Cookie Extraction Libraries
Instead of Rust's `rookie` crate, use equivalent libraries for your language:
* **Node.js:** `browser-cookies` or `chrome-cookies-secure`
* **Python:** `browser-cookie3` or `rookiepy` (Python binding for Rookie)
* **Go:** `github.com/zellyn/kooky`

### 2. Request Setup
Ensure your HTTP client wraps or intercepts all outgoing requests to JIRA/Confluence.
* If a session cookie is supplied:
  * Extract domain cookies, format as `key=value; key2=value2`
  * Add the `Cookie` header.
  * **Crucial:** Add `X-Atlassian-Token: no-check` header.
* If Email & API Token are supplied:
  * Base64 encode the string `"{email}:{token}"`
  * Add `Authorization: Basic {base64_string}` header.

### 3. Graceful Fallbacks
Create a UX flow where:
1. Credentials from local config or environment variables are verified first.
2. If absent, attempt background extraction of cookies for Atlassian domains.
3. If background extraction fails, prompt the user to:
   * Perform an explicit login/session grab.
   * Provide their email and Atlassian API token.

---

## 6. Replication Strategy for Bash (Shell Scripting)

If you are building lightweight command-line automation, you can implement this architecture directly in Bash using standard tools like `curl`, `base64`, and `sqlite3`.

### A. Basic Auth in Bash
To replicate API Token authentication, base64-encode the `email:api_token` string:

```bash
#!/bin/bash
DOMAIN="your-domain"
EMAIL="your-email@domain.com"
API_TOKEN="your_jira_api_token"

# Base64 encode credentials
AUTH_HEADER=$(echo -n "${EMAIL}:${API_TOKEN}" | base64)

# Execute API Request
curl -s -X GET \
  -H "Authorization: Basic ${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  "https://${DOMAIN}.atlassian.net/rest/api/3/myself"
```

### B. Cookie Auth in Bash
When passing an existing session cookie string, remember that Atlassian APIs **require** the anti-CSRF header (`X-Atlassian-Token: no-check`) to avoid being blocked:

```bash
#!/bin/bash
DOMAIN="your-domain"
COOKIE="tenant.session.token=xxxx; ..." # Full cookie string

curl -s -X GET \
  -H "Cookie: ${COOKIE}" \
  -H "X-Atlassian-Token: no-check" \
  -H "Content-Type: application/json" \
  "https://${DOMAIN}.atlassian.net/rest/api/3/myself"
```

### C. Extracting Browser Cookies in Bash
Automating cookie extraction in pure shell scripts has varied complexity depending on the browser:

#### 1. Firefox (Unencrypted Cookies)
Since Firefox does not encrypt individual cookie values in its SQLite database, you can extract them directly using the `sqlite3` CLI:

```bash
#!/bin/bash
DOMAIN="your-domain"

# Locate Firefox profile directory (Linux example)
FF_PROFILE_DIR=$(find ~/.mozilla/firefox -maxdepth 2 -name "*.default-release" | head -n 1)
COOKIES_DB="${FF_PROFILE_DIR}/cookies.sqlite"

if [ -f "$COOKIES_DB" ]; then
  # Query SQLite database for Atlassian session cookies
  COOKIE_STRING=$(sqlite3 "$COOKIES_DB" \
    "SELECT name || '=' || value FROM moz_cookies WHERE host LIKE '%${DOMAIN}.atlassian.net'" \
    | paste -sd "; " -)
  
  echo "Extracted Cookie: ${COOKIE_STRING}"
else
  echo "Firefox cookies database not found."
fi
```

#### 2. Chrome/Chromium (Encrypted Cookies)
Chrome encrypts cookie stores using OS-specific credential managers (Keychain on macOS, DPAPI on Windows, GNOME Keyring/KWallet on Linux) via AES-GCM. 

While raw decryption in pure Bash is extremely complex, you can easily bridge the gap using a inline python script that utilizes a library like `rookiepy` (the Python equivalent of the Rust `rookie` crate):

```bash
#!/bin/bash
DOMAIN="your-domain"

# Pull decrypted session cookies via rookiepy
COOKIE_STRING=$(python3 -c "
import rookiepy
try:
    cookies = rookiepy.chrome(['${DOMAIN}.atlassian.net'])
    cookie_str = '; '.join([f\"{c['name']}={c['value']}\" for c in cookies])
    print(cookie_str)
except Exception:
    pass
" 2>/dev/null)

if [ -n "$COOKIE_STRING" ]; then
  # Use the extracted cookie to make the curl request
  curl -s -X GET \
    -H "Cookie: ${COOKIE_STRING}" \
    -H "X-Atlassian-Token: no-check" \
    "https://${DOMAIN}.atlassian.net/rest/api/3/myself"
else
  echo "No active Chrome cookies found. Are you logged in?"
fi
```
