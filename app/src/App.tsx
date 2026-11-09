import { FormEvent, useEffect, useMemo, useState } from "react";
import type { Todo } from "./types";

type Filter = "all" | "active" | "completed";

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, {
    ...init,
    headers: {
      ...(init?.body ? { "Content-Type": "application/json" } : {}),
      ...init?.headers,
    },
  });

  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? "Something went wrong. Please try again.");
  }

  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

const filters: { label: string; value: Filter }[] = [
  { label: "All tasks", value: "all" },
  { label: "To do", value: "active" },
  { label: "Done", value: "completed" },
];

function CheckIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" aria-hidden="true" className="h-5 w-5">
      <path d="m5 12.5 4.2 4.2L19 7" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function App() {
  const [todos, setTodos] = useState<Todo[]>([]);
  const [filter, setFilter] = useState<Filter>("all");
  const [draft, setDraft] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    request<Todo[]>("/api/todos")
      .then(setTodos)
      .catch((cause: unknown) =>
        setError(cause instanceof Error ? cause.message : "Could not load your tasks."),
      )
      .finally(() => setLoading(false));
  }, []);

  const completedCount = todos.filter((todo) => todo.completed).length;
  const remainingCount = todos.length - completedCount;
  const visibleTodos = useMemo(
    () =>
      todos.filter((todo) => {
        if (filter === "active") return !todo.completed;
        if (filter === "completed") return todo.completed;
        return true;
      }),
    [filter, todos],
  );

  async function addTodo(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const text = draft.trim();
    if (!text || saving) return;

    setSaving(true);
    setError("");
    try {
      const todo = await request<Todo>("/api/todos", {
        method: "POST",
        body: JSON.stringify({ text }),
      });
      setTodos((current) => [todo, ...current]);
      setDraft("");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not add that task.");
    } finally {
      setSaving(false);
    }
  }

  async function toggleTodo(todo: Todo) {
    setError("");
    try {
      const updated = await request<Todo>(`/api/todos/${todo.id}`, {
        method: "PATCH",
        body: JSON.stringify({ completed: !todo.completed }),
      });
      setTodos((current) => current.map((item) => (item.id === updated.id ? updated : item)));
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not update that task.");
    }
  }

  async function deleteTodo(todo: Todo) {
    setError("");
    try {
      await request<void>(`/api/todos/${todo.id}`, { method: "DELETE" });
      setTodos((current) => current.filter((item) => item.id !== todo.id));
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not delete that task.");
    }
  }

  async function clearCompleted() {
    setError("");
    try {
      await request<{ deletedCount: number }>("/api/todos/completed", { method: "DELETE" });
      setTodos((current) => current.filter((todo) => !todo.completed));
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not clear completed tasks.");
    }
  }

  return (
    <main className="min-h-screen px-5 pb-16 pt-12 sm:px-8 sm:pt-20">
      <div className="mx-auto max-w-[680px]">
        <header className="mb-9 flex items-center justify-between">
          <a href="/" className="flex items-center gap-3" aria-label="Daylist home">
            <span className="grid h-10 w-10 place-items-center rounded-2xl bg-leaf text-white shadow-sm">
              <CheckIcon />
            </span>
            <span className="text-[17px] font-semibold tracking-tight text-ink">daylist</span>
          </a>
          <span className="rounded-full border border-stone-200/80 bg-white/70 px-3.5 py-2 text-xs font-medium text-muted">
            A little more focus
          </span>
        </header>

        <section className="overflow-hidden rounded-[28px] border border-stone-200/70 bg-white shadow-card">
          <div className="px-6 pb-6 pt-8 sm:px-10 sm:pb-8 sm:pt-10">
            <p className="mb-3 text-xs font-semibold uppercase tracking-[0.17em] text-leaf">
              Your space to focus
            </p>
            <div className="flex flex-wrap items-end justify-between gap-4">
              <div>
                <h1 className="text-3xl font-semibold tracking-[-0.04em] text-ink sm:text-[38px]">
                  Make today count.
                </h1>
                <p className="mt-2 text-sm text-muted">
                  One thing at a time. You’ve got this.
                </p>
              </div>
              <div className="pb-0.5 text-right">
                <p className="text-2xl font-semibold tracking-tight text-ink">{remainingCount}</p>
                <p className="text-xs text-muted">left to do</p>
              </div>
            </div>

            <form onSubmit={addTodo} className="mt-8 flex gap-2.5">
              <label htmlFor="new-todo" className="sr-only">Add a task</label>
              <input
                id="new-todo"
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                maxLength={200}
                placeholder="What needs your attention?"
                className="min-w-0 flex-1 rounded-xl border border-stone-200 bg-paper px-4 py-3.5 text-sm text-ink outline-none transition placeholder:text-stone-400 focus:border-leaf/50 focus:bg-white focus:ring-4 focus:ring-leaf/10"
              />
              <button
                type="submit"
                disabled={!draft.trim() || saving}
                className="rounded-xl bg-leaf px-5 text-sm font-semibold text-white transition hover:bg-[#3b654c] focus:outline-none focus:ring-4 focus:ring-leaf/20 disabled:cursor-not-allowed disabled:opacity-45"
              >
                {saving ? "Adding…" : "Add task"}
              </button>
            </form>

            {error && (
              <p role="alert" className="mt-3 text-sm text-red-600">{error}</p>
            )}
          </div>

          <div className="border-y border-stone-100 px-6 sm:px-10">
            <div className="flex items-center justify-between gap-3">
              <nav className="flex gap-5" aria-label="Filter tasks">
                {filters.map((item) => (
                  <button
                    key={item.value}
                    type="button"
                    onClick={() => setFilter(item.value)}
                    aria-current={filter === item.value ? "page" : undefined}
                    className={`relative py-4 text-sm transition ${
                      filter === item.value
                        ? "font-semibold text-leaf after:absolute after:inset-x-0 after:bottom-0 after:h-0.5 after:rounded-full after:bg-leaf"
                        : "text-muted hover:text-ink"
                    }`}
                  >
                    {item.label}
                    {item.value === "all" && (
                      <span className="ml-1.5 text-xs text-stone-400">{todos.length}</span>
                    )}
                  </button>
                ))}
              </nav>
              {completedCount > 0 && (
                <button
                  type="button"
                  onClick={clearCompleted}
                  className="text-xs font-medium text-muted transition hover:text-ink"
                >
                  Clear done
                </button>
              )}
            </div>
          </div>

          <div className="min-h-[250px] px-6 py-2 sm:px-10">
            {loading ? (
              <p className="py-12 text-center text-sm text-muted">Loading your tasks…</p>
            ) : visibleTodos.length ? (
              <ul>
                {visibleTodos.map((todo) => (
                  <li
                    key={todo.id}
                    className="group flex min-h-[66px] items-center gap-3 border-b border-stone-100 last:border-0"
                  >
                    <button
                      type="button"
                      onClick={() => toggleTodo(todo)}
                      aria-label={todo.completed ? `Mark ${todo.text} as to do` : `Complete ${todo.text}`}
                      aria-pressed={todo.completed}
                      className={`grid h-[22px] w-[22px] shrink-0 place-items-center rounded-full border transition ${
                        todo.completed
                          ? "border-leaf bg-leaf text-white"
                          : "border-stone-300 text-transparent hover:border-leaf"
                      }`}
                    >
                      <CheckIcon />
                    </button>
                    <span
                      className={`flex-1 break-words py-3 text-sm ${
                        todo.completed ? "text-stone-400 line-through" : "text-ink"
                      }`}
                    >
                      {todo.text}
                    </span>
                    <button
                      type="button"
                      onClick={() => deleteTodo(todo)}
                      aria-label={`Delete ${todo.text}`}
                      className="rounded-md px-2 py-1 text-lg leading-none text-stone-300 opacity-100 transition hover:text-red-500 sm:opacity-0 sm:group-hover:opacity-100 sm:focus:opacity-100"
                    >
                      ×
                    </button>
                  </li>
                ))}
              </ul>
            ) : (
              <div className="flex min-h-[250px] flex-col items-center justify-center py-10 text-center">
                <span className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-[#edf3ed] text-leaf">
                  <CheckIcon />
                </span>
                <p className="text-sm font-medium text-ink">
                  {filter === "completed"
                    ? "Nothing completed just yet"
                    : filter === "active" && todos.length > 0
                      ? "You’re all caught up"
                      : "A fresh start"}
                </p>
                <p className="mt-1.5 max-w-[240px] text-xs leading-5 text-muted">
                  {filter === "completed"
                    ? "Finish a task and it’ll find its way here."
                    : filter === "active" && todos.length > 0
                      ? "Take a moment to enjoy that feeling."
                      : "Add your first task above and take it from there."}
                </p>
              </div>
            )}
          </div>

          <footer className="flex flex-wrap items-center justify-between gap-2 border-t border-stone-100 bg-[#fdfdfc] px-6 py-4 text-xs text-muted sm:px-10">
            <span>{remainingCount === 1 ? "1 task" : `${remainingCount} tasks`} remaining</span>
            <span>{completedCount > 0 ? `${completedCount} done — nice work` : "Small steps add up"}</span>
          </footer>
        </section>
        <p className="mt-6 text-center text-xs text-stone-400">
          Keep it simple. Keep moving.
        </p>
      </div>
    </main>
  );
}

export default App;
