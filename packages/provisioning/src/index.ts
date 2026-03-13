/**
 * @semantius/provisioning - Hono server for Cloudflare Workers
 *
 * Routes:
 *   POST /migrate  — Run database migrations
 *   GET  /test     — Interactive HTML form to trigger migrations
 */

import { Hono } from "hono";
import { migrate } from "./migrate.js";

type Bindings = {
  DATABASE_URL?: string;
};

const app = new Hono<{ Bindings: Bindings }>();

/**
 * POST /migrate
 *
 * Accepts a JSON body with:
 *   - database_url: string (required)
 *   - modules: string[]   (optional, defaults to all bundled apps)
 *
 * Returns JSON with migration result.
 */
app.post("/migrate", async (c) => {
  let body: { database_url?: string; modules?: string[] };

  try {
    body = await c.req.json();
  } catch {
    return c.json({ success: false, error: "Invalid JSON body" }, 400);
  }

  const databaseUrl = body.database_url ?? c.env?.DATABASE_URL;

  if (!databaseUrl) {
    return c.json(
      {
        success: false,
        error:
          "database_url must be provided in the request body or set as the DATABASE_URL environment variable",
      },
      400,
    );
  }

  try {
    const result = await migrate(databaseUrl, body.modules, { verbose: true });
    return c.json(result);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json({ success: false, error: message }, 500);
  }
});

/**
 * GET /test
 *
 * Returns a static HTML form for interactively triggering migrations.
 * Modules are entered as a comma-separated list and converted to an array
 * before POSTing to /migrate.
 */
app.get("/test", (c) => {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Semantius Provisioning</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; }
    h1 { font-size: 1.5rem; margin-bottom: 1.5rem; }
    label { display: block; font-weight: 600; margin-bottom: 4px; }
    textarea, input[type="text"] {
      width: 100%; box-sizing: border-box; padding: 8px;
      border: 1px solid #ccc; border-radius: 4px;
      font-family: monospace; font-size: 0.875rem; margin-bottom: 16px;
    }
    textarea { height: 80px; resize: vertical; }
    button {
      padding: 10px 24px; background: #2563eb; color: #fff;
      border: none; border-radius: 4px; cursor: pointer; font-size: 1rem;
    }
    button:disabled { background: #93c5fd; cursor: not-allowed; }
    #response {
      margin-top: 24px; padding: 16px; background: #f8fafc;
      border: 1px solid #e2e8f0; border-radius: 4px;
      white-space: pre-wrap; font-family: monospace; font-size: 0.875rem;
      display: none;
    }
    #response.error { border-color: #fca5a5; background: #fff1f2; }
    #response.success { border-color: #86efac; background: #f0fdf4; }
  </style>
</head>
<body>
  <h1>Semantius Provisioning</h1>
  <form id="form">
    <label for="database_url">Database URL</label>
    <textarea id="database_url" name="database_url" placeholder="postgresql://user:password@host:5432/database" required></textarea>

    <label for="modules">Modules <small style="font-weight:normal">(comma-separated, e.g. _core,nwind)</small></label>
    <input type="text" id="modules" name="modules" placeholder="_core" />

    <button type="submit" id="submit-btn">Provision</button>
  </form>

  <div id="response"></div>

  <script>
    document.getElementById('form').addEventListener('submit', async function(e) {
      e.preventDefault();

      const btn = document.getElementById('submit-btn');
      const responseEl = document.getElementById('response');

      const databaseUrl = document.getElementById('database_url').value.trim();
      const modulesRaw = document.getElementById('modules').value.trim();
      const modules = modulesRaw
        ? modulesRaw.split(',').map(m => m.trim()).filter(m => m.length > 0)
        : [];

      btn.textContent = 'Provisioning...';
      btn.disabled = true;
      responseEl.style.display = 'none';
      responseEl.className = '';

      try {
        const res = await fetch('/migrate', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ database_url: databaseUrl, modules })
        });

        const data = await res.json();
        responseEl.textContent = JSON.stringify(data, null, 2);
        responseEl.className = data.success ? 'success' : 'error';
        responseEl.style.display = 'block';
      } catch (err) {
        responseEl.textContent = 'Request failed: ' + (err instanceof Error ? err.message : String(err));
        responseEl.className = 'error';
        responseEl.style.display = 'block';
      } finally {
        btn.textContent = 'Provision';
        btn.disabled = false;
      }
    });
  </script>
</body>
</html>`;

  return c.html(html);
});

export default app;
