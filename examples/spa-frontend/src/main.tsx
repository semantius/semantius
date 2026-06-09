import { createRoot } from "react-dom/client";
import { RouterProvider } from "@tanstack/react-router";
import { AuthProvider, useAuth } from "./auth/AuthContext";
import { router } from "./router";
import "./styles.css";

// AuthProvider (react-oauth2-code-pkce) wraps everything so the token lifecycle —
// including the /oauth2_callback code exchange — runs regardless of route. InnerApp
// feeds the live auth state into the router's context, so route guards (beforeLoad)
// see the current auth and re-evaluate when it changes.
//
// NOTE: no <StrictMode> — its dev double-invoke can run the one-time code exchange
// twice (the single-use code fails the 2nd time).
function InnerApp() {
  const auth = useAuth();
  return <RouterProvider router={router} context={{ auth }} />;
}

const root = document.getElementById("root");
if (!root) throw new Error("missing #root element");
createRoot(root).render(
  <AuthProvider>
    <InnerApp />
  </AuthProvider>,
);
