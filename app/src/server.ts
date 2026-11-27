import express from "express";
import path from "node:path";
import { Pool } from "pg";
import type { Request, RequestHandler, Response } from "express";

const app = express();
const port = Number(process.env.PORT ?? 5000);
const host = process.env.HOST ?? "127.0.0.1";
const pool = new Pool({
  host: process.env.DB_HOST ?? "127.0.0.1",
  port: Number(process.env.DB_PORT ?? 5432),
  database: process.env.DB_NAME ?? "taskops",
  user: process.env.DB_USER ?? "taskops_app",
  password: process.env.DB_PASSWORD,
});

const asyncRoute = (
  handler: (request: Request, response: Response) => Promise<void>,
): RequestHandler => (request, response, next) => {
  void handler(request, response).catch(next);
};

function isTaskId(value: string): boolean {
  return /^[1-9]\d*$/.test(value);
}

app.use(express.json());

app.get(
  "/api/todos",
  asyncRoute(async (_request, response) => {
    const result = await pool.query(
      `SELECT id::text, text, completed, created_at AS "createdAt"
       FROM tasks
       ORDER BY created_at DESC, id DESC`,
    );
    response.json(result.rows);
  }),
);

app.post(
  "/api/todos",
  asyncRoute(async (request, response) => {
    const text = request.body?.text;
    if (typeof text !== "string" || !text.trim()) {
      response.status(400).json({ error: "Todo text is required." });
      return;
    }
    if (text.trim().length > 200) {
      response.status(400).json({ error: "Todo text must be 200 characters or fewer." });
      return;
    }

    const result = await pool.query(
      `INSERT INTO tasks (text)
       VALUES ($1)
       RETURNING id::text, text, completed, created_at AS "createdAt"`,
      [text.trim()],
    );
    response.status(201).json(result.rows[0]);
  }),
);

app.patch(
  "/api/todos/:id",
  asyncRoute(async (request, response) => {
    const id = request.params.id;
    if (typeof id !== "string" || !isTaskId(id)) {
      response.status(400).json({ error: "Todo ID must be a positive integer." });
      return;
    }
    if (typeof request.body?.completed !== "boolean") {
      response.status(400).json({ error: "A completed value is required." });
      return;
    }

    const result = await pool.query(
      `UPDATE tasks
       SET completed = $1
       WHERE id = $2
       RETURNING id::text, text, completed, created_at AS "createdAt"`,
      [request.body.completed, id],
    );
    if (result.rowCount === 0) {
      response.status(404).json({ error: "Todo not found." });
      return;
    }
    response.json(result.rows[0]);
  }),
);

app.delete(
  "/api/todos/completed",
  asyncRoute(async (_request, response) => {
    const result = await pool.query("DELETE FROM tasks WHERE completed = TRUE");
    response.json({ deletedCount: result.rowCount ?? 0 });
  }),
);

app.delete(
  "/api/todos/:id",
  asyncRoute(async (request, response) => {
    const id = request.params.id;
    if (typeof id !== "string" || !isTaskId(id)) {
      response.status(400).json({ error: "Todo ID must be a positive integer." });
      return;
    }

    const result = await pool.query("DELETE FROM tasks WHERE id = $1", [id]);
    if (result.rowCount === 0) {
      response.status(404).json({ error: "Todo not found." });
      return;
    }
    response.status(204).end();
  }),
);

const staticDirectory = path.resolve(__dirname, "../static");
app.use(express.static(staticDirectory));
app.get("*", (request, response, next) => {
  if (request.path.startsWith("/api/")) {
    next();
    return;
  }
  response.sendFile(path.join(staticDirectory, "index.html"));
});

app.use((error: unknown, _request: Request, response: Response, _next: (error?: unknown) => void) => {
  console.error("Request failed:", error);
  if (!response.headersSent) {
    response.status(500).json({ error: "An unexpected server error occurred." });
  }
});

async function startServer() {
  await pool.query("SELECT 1");
  app.listen(port, host, () => {
    console.log(`TaskOps is listening at http://${host}:${port}`);
  });
}

void startServer().catch((error: unknown) => {
  console.error("Could not connect to PostgreSQL:", error);
  void pool.end().finally(() => {
    process.exitCode = 1;
  });
});
