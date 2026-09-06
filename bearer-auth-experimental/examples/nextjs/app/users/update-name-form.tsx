"use client";

import { useActionState } from "react";
import { updateMyDisplayName, type ActionResult } from "./actions";

export function UpdateNameForm({ current }: { current: string }) {
  const [state, action, pending] = useActionState<ActionResult | null, FormData>(
    updateMyDisplayName,
    null,
  );

  return (
    <form action={action}>
      <label>
        <div className="muted" style={{ marginBottom: "0.35rem" }}>
          Your display name
        </div>
        <input
          type="text"
          name="displayName"
          defaultValue={current}
          disabled={pending}
        />
      </label>{" "}
      <button type="submit" disabled={pending}>
        {pending ? "Saving…" : "Save"}
      </button>
      {state && (
        <p className={state.ok ? "result-ok" : "result-err"}>{state.message}</p>
      )}
    </form>
  );
}
