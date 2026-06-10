import { createBrowserRouter } from "react-router-dom"

import { AppShell } from "@/components/layout/app-shell"
import { DashboardPage } from "@/pages/dashboard-page"
import { LoginPage } from "@/pages/login-page"
import { PlaceholderPage } from "@/pages/placeholder-page"
import { UnauthorizedPage } from "@/pages/unauthorized-page"
import { GuardedRoute } from "@/routes/guarded-route"
import { RoleRoute } from "@/routes/role-route"

export const router = createBrowserRouter([
  {
    path: "/login",
    element: <LoginPage />,
  },
  {
    path: "/unauthorized",
    element: <UnauthorizedPage />,
  },
  {
    element: <GuardedRoute />,
    children: [
      {
        element: <AppShell />,
        children: [
          { path: "/", element: <DashboardPage /> },
          {
            path: "/requests",
            element: (
              <PlaceholderPage
                title="Part Requests"
                subtitle="Core part request workflow UI lands in Phase 3."
              />
            ),
          },
          {
            element: <RoleRoute allowedRoles={["warehouse_controller", "service_manager"]} />,
            children: [
              {
                path: "/inventory",
                element: (
                  <PlaceholderPage
                    title="Inventory"
                    subtitle="Inventory operations are enabled after DB workflow RPCs are introduced."
                  />
                ),
              },
            ],
          },
          {
            path: "/transfers",
            element: (
              <PlaceholderPage
                title="Transfers"
                subtitle="Transfer workflow UI is implemented in advanced workflow phase."
              />
            ),
          },
          {
            element: <RoleRoute allowedRoles={["warehouse_controller", "service_manager", "finance_admin"]} />,
            children: [
              {
                path: "/sales",
                element: (
                  <PlaceholderPage
                    title="Cash Sales"
                    subtitle="Cash-sale lifecycle and reconciliation controls are implemented in Phase 5."
                  />
                ),
              },
            ],
          },
          {
            element: <RoleRoute allowedRoles={["dispatcher", "service_manager"]} />,
            children: [
              {
                path: "/team",
                element: (
                  <PlaceholderPage
                    title="Team View"
                    subtitle="Dispatch coordination screens are implemented in later phases."
                  />
                ),
              },
            ],
          },
        ],
      },
    ],
  },
])
