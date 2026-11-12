"""Server tiruan Supabase (GoTrue + PostgREST minimal) di atas Postgres lokal, untuk menguji frontend.

    python3 supabase/test/mock_supabase.py 8790 /path/ke/folder/aplikasi
Aplikasi dilayani di http://localhost:8790/ dan API di URL yang sama.
"""
import base64, json, os, sys, time, urllib.parse
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import psycopg
from psycopg.types.json import Jsonb

PORT = int(sys.argv[1]); ROOT = sys.argv[2]
DSN = os.environ.get("UCS_DSN", "host=/tmp port=54329 dbname=ucs user=postgres")

def b64(d): return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
def jwt(uid, email): return b64({"alg": "HS256", "typ": "JWT"}) + "." + b64({"sub": uid, "email": email, "role": "authenticated", "exp": int(time.time()) + 3600}) + ".sig"
def uid_from(tok):
    try: return json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "==="))["sub"]
    except Exception: return None

class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def log_message(self, *a): pass
    def send_json(self, code, obj):
        b = json.dumps(obj, default=str).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return json.loads(self.rfile.read(n) or b"{}")
    def who(self):
        a = self.headers.get("Authorization", ""); t = a[7:] if a.startswith("Bearer ") else ""
        return (uid_from(t), "authenticated") if uid_from(t) else ("", "anon")
    def run(self, sql, params, uid, role):
        with psycopg.connect(DSN) as c:
            with c.transaction():
                cur = c.cursor(); cur.execute("set local role " + role)
                cur.execute("select set_config('request.jwt.claim.sub', %s, true)", (uid or "",))
                cur.execute(sql, params); return cur.fetchall() if cur.description else []
    def pg_error(self, e):
        d = getattr(e, "diag", None); code = getattr(e, "sqlstate", None) or "P0001"
        self.send_json(403 if code == "42501" else 400, {"code": code, "message": d.message_primary if d else str(e), "details": None, "hint": None})
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if not u.path.startswith("/rest/v1/"): return super().do_GET()
        table = u.path.split("/")[-1]; q = urllib.parse.parse_qs(u.query); where = []; params = []; order = ""; limit = ""
        for k, vals in q.items():
            v = vals[0]
            if k == "select": continue
            if k == "order": order = " order by " + ", ".join(f'"{p.split(".")[0]}" {p.split(".")[1] if "." in p else "asc"}' for p in v.split(",")); continue
            if k == "limit": limit = " limit %d" % int(v); continue
            op, val = v.split(".", 1); assert op == "eq"; where.append(f'"{k}"::text = %s'); params.append(val)
        sql = f'select coalesce(json_agg(t), \'[]\') from (select * from public."{table}"' + (" where " + " and ".join(where) if where else "") + order + limit + ") t"
        uid, role = self.who()
        try: self.send_json(200, self.run(sql, params, uid, role)[0][0])
        except psycopg.Error as e: self.pg_error(e)
    def do_POST(self):
        u = urllib.parse.urlparse(self.path); uid, role = self.who()
        if u.path == "/auth/v1/token":
            b = self.body()
            r = self.run("select id::text, email from auth.users where lower(email)=lower(%s) and encrypted_password = extensions.crypt(%s, encrypted_password)", (b.get("email"), b.get("password")), "", "postgres")
            if not r: return self.send_json(400, {"error": "invalid_grant", "error_description": "Invalid login credentials", "code": 400, "msg": "Invalid login credentials"})
            i, em = r[0]; now = int(time.time())
            return self.send_json(200, {"access_token": jwt(i, em), "token_type": "bearer", "expires_in": 3600, "expires_at": now + 3600, "refresh_token": "r-" + i,
                                        "user": {"id": i, "aud": "authenticated", "role": "authenticated", "email": em, "app_metadata": {}, "user_metadata": {}, "created_at": "2026-11-12T00:00:00Z"}})
        if u.path == "/auth/v1/logout":
            self.send_response(204); self.end_headers(); return
        if u.path.startswith("/rest/v1/rpc/"):
            fn = u.path.split("/")[-1]; b = self.body()
            args = ", ".join(f"{k} => %s" for k in b); vals = [Jsonb(v) if isinstance(v, (dict, list)) else v for v in b.values()]
            try:
                r = self.run(f"select to_json(public.{fn}({args}))", vals, uid, role)
                return self.send_json(200, r[0][0] if r else None)
            except psycopg.Error as e: return self.pg_error(e)
        self.send_json(404, {"message": "not found"})
    def do_OPTIONS(self):
        self.send_response(204); self.end_headers()

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
