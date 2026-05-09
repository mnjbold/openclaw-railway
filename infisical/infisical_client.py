"""
infisical_client.py — Lightweight Infisical secrets client for JEWE Stack services.

No external dependencies (uses only stdlib). Drop into any Python service.

Usage:
    from infisical_client import InfisicalVault
    
    vault = InfisicalVault()  # reads config from env vars
    
    # Get all secrets for a service
    secrets = vault.get_secrets("/openclaw")
    
    # Get a single secret
    api_key = vault.get_secret("/shared", "RAILWAY_PROJECT_TOKEN")
    
    # Export all secrets to os.environ
    vault.export_to_env("/hermes-agent")
    
    # Get secrets from multiple paths at once
    all_secrets = vault.get_secrets_multi(["/openclaw", "/shared"])
"""

import json
import os
import urllib.request
import urllib.error
from typing import Optional
import time
import threading


class InfisicalVault:
    """Thread-safe Infisical secrets client with token caching."""
    
    def __init__(
        self,
        url: Optional[str] = None,
        client_id: Optional[str] = None,
        client_secret: Optional[str] = None,
        project_id: Optional[str] = None,
        environment: str = "prod",
    ):
        self.url = (url or os.environ.get("INFISICAL_URL", "")).rstrip("/")
        self.client_id = client_id or os.environ.get("INFISICAL_CLIENT_ID", "")
        self.client_secret = client_secret or os.environ.get("INFISICAL_CLIENT_SECRET", "")
        self.project_id = project_id or os.environ.get("INFISICAL_PROJECT_ID", "")
        self.environment = environment or os.environ.get("INFISICAL_ENV", "prod")
        
        self._token: Optional[str] = None
        self._token_expires: float = 0
        self._lock = threading.Lock()
        
        if not all([self.url, self.client_id, self.client_secret, self.project_id]):
            raise ValueError(
                "Missing Infisical config. Set INFISICAL_URL, INFISICAL_CLIENT_ID, "
                "INFISICAL_CLIENT_SECRET, and INFISICAL_PROJECT_ID env vars."
            )
    
    def _request(self, method: str, path: str, data: Optional[dict] = None, token: Optional[str] = None) -> dict:
        """Make an HTTP request to Infisical API."""
        url = f"{self.url}{path}"
        body = json.dumps(data).encode() if data else None
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else ""
            raise RuntimeError(f"Infisical API error {e.code}: {error_body}")
    
    def _authenticate(self) -> str:
        """Get or refresh access token (thread-safe, cached)."""
        with self._lock:
            if self._token and time.time() < self._token_expires - 60:
                return self._token
            
            resp = self._request("POST", "/api/v1/auth/universal-auth/login", {
                "clientId": self.client_id,
                "clientSecret": self.client_secret,
            })
            
            self._token = resp["accessToken"]
            self._token_expires = time.time() + resp.get("expiresIn", 2592000)
            return self._token
    
    @property
    def token(self) -> str:
        return self._authenticate()
    
    def get_secrets(self, secret_path: str = "/") -> dict[str, str]:
        """Fetch all secrets from a path. Returns {key: value} dict."""
        token = self.token
        params = f"workspaceId={self.project_id}&environment={self.environment}&secretPath={secret_path}"
        resp = self._request("GET", f"/api/v3/secrets/raw?{params}", token=token)
        return {s["secretKey"]: s["secretValue"] for s in resp.get("secrets", [])}
    
    def get_secret(self, secret_path: str, key: str) -> Optional[str]:
        """Fetch a single secret by key."""
        secrets = self.get_secrets(secret_path)
        return secrets.get(key)
    
    def get_secrets_multi(self, paths: list[str]) -> dict[str, str]:
        """Fetch secrets from multiple paths, merged into one dict. Later paths override."""
        result = {}
        for path in paths:
            result.update(self.get_secrets(path))
        return result
    
    def export_to_env(self, *paths: str) -> int:
        """Export secrets from one or more paths into os.environ. Returns count."""
        count = 0
        for path in paths:
            secrets = self.get_secrets(path)
            os.environ.update(secrets)
            count += len(secrets)
        return count


# CLI usage
if __name__ == "__main__":
    import sys
    vault = InfisicalVault()
    path = sys.argv[1] if len(sys.argv) > 1 else "/"
    secrets = vault.get_secrets(path)
    for k, v in sorted(secrets.items()):
        masked = v[:4] + "..." if len(v) > 8 else v
        print(f"  {k} = {masked}")
    print(f"\n{len(secrets)} secrets retrieved from {path}")
