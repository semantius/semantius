// =============================================================================
// TanStack Router route tree (code-based). Three routes:
//   /                  home (sign-in status)
//   /users             RLS-enforced list + write demo — AUTH-GUARDED
//   /oauth2_callback   the issuer redirect target
//
// Authenticated-route handling (the idiomatic TanStack pattern): auth state is
// fed into the router via `context` (see main.tsx → RouterProvider context prop),
// and the protected route's `beforeLoad` redirects unauthenticated users BEFORE
// the route loads. Because the router context comes from the live `useAuth()`,
// `beforeLoad` re-evaluates whenever auth changes.
// =============================================================================

import { useEffect } from "react";
import {
  createRootRouteWithContext,
  createRoute,
  createRouter,
  redirect,
  useNavigate,
  useRouter,
  Link,
  Outlet,
} from "@tanstack/react-router";
import { useAuth, type AuthValue } from "./auth/AuthContext";
import { Home } from "./pages/Home";
import { Users } from "./pages/Users";
import { Audit } from "./pages/Audit";

export interface RouterContext {
  auth: AuthValue;
}

// Preserve the originally-requested route across the external IdP round-trip.
// Login leaves the app entirely and returns to the fixed /oauth2_callback, so a
// search param on a login route would NOT survive — sessionStorage does. The
// callback restores this exact href; DEFAULT_AUTHED_ROUTE is only the fallback
// when login was started without a specific destination (e.g. from Home).
const RETURN_TO_KEY = "semantius.returnTo";
const DEFAULT_AUTHED_ROUTE = "/users";

function stashReturnTo(href: string): void {
  sessionStorage.setItem(RETURN_TO_KEY, href);
}
function popReturnTo(): string {
  const href = sessionStorage.getItem(RETURN_TO_KEY);
  sessionStorage.removeItem(RETURN_TO_KEY);
  return href || DEFAULT_AUTHED_ROUTE;
}

const rootRoute = createRootRouteWithContext<RouterContext>()({
  component: RootLayout,
});

function RootLayout() {
  const { status, logout } = useAuth();
  const navigate = useNavigate();
  return (
    <div className="container">
      <header className="topbar">
        <strong>Semantius · React SPA + Hono API</strong>
        <nav>
          <Link to="/">Home</Link>
          {status === "authenticated" && (
            <>
              <Link to="/users">Users</Link>
              <Link to="/audit">Audit</Link>
              <button
                className="linkbtn"
                onClick={() => {
                  logout();
                  void navigate({ to: "/" });
                }}
              >
                Sign out
              </button>
            </>
          )}
        </nav>
      </header>
      <Outlet />
    </div>
  );
}

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: Home,
});

const usersRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "users",
  // Auth guard: bounce explicitly-unauthenticated visitors home BEFORE loading,
  // remembering where they were headed so login returns them there.
  // ('loading' — a token rehydrating/refreshing — is allowed through; the page
  // shows its own loading state, avoiding a bounce mid-refresh on reload.)
  beforeLoad: ({ context, location }) => {
    if (context.auth.status === "unauthenticated") {
      stashReturnTo(location.href);
      throw redirect({ to: "/" });
    }
  },
  component: Users,
});

const auditRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "audit",
  // Same auth guard as /users.
  beforeLoad: ({ context, location }) => {
    if (context.auth.status === "unauthenticated") {
      stashReturnTo(location.href);
      throw redirect({ to: "/" });
    }
  },
  component: Audit,
});

const callbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "oauth2_callback",
  component: CallbackPage,
});

/** The issuer redirect target. react-oauth2-code-pkce (mounted above the router)
 * exchanges the ?code= and flips auth state; we just react to it. NOT auth-guarded
 * — you aren't authenticated yet when the code arrives. */
function CallbackPage() {
  const { status, error } = useAuth();
  const router = useRouter();
  useEffect(() => {
    // The lib has exchanged the code → return the user to wherever the guard sent
    // them from (or the default landing). history.replace takes a raw href, so the
    // captured path — query/hash and all — is restored exactly (not a hardcode).
    if (status === "authenticated") router.history.replace(popReturnTo());
    else if (status === "unauthenticated" && !error) router.history.replace("/");
  }, [status, error, router]);

  if (error) {
    return (
      <div className="card">
        <p className="err">Sign-in failed: {error}</p>
        <p>
          <Link to="/">← Home</Link>
        </p>
      </div>
    );
  }
  return <p className="muted">Completing sign-in…</p>;
}

const routeTree = rootRoute.addChildren([indexRoute, usersRoute, auditRoute, callbackRoute]);

// `auth` is a placeholder here; the real value is injected by RouterProvider's
// `context` prop in main.tsx (which carries the live useAuth() value).
export const router = createRouter({
  routeTree,
  context: { auth: undefined! },
});

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
