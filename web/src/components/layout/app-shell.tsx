import { LogOut } from "lucide-react"
import { NavLink, Outlet } from "react-router-dom"

import { APP_NAV_ITEMS } from "@/config/navigation"
import { ROLE_LABELS } from "@/config/roles"
import { Button } from "@/components/ui/button"
import { useAuth } from "@/hooks/use-auth"
import { cn } from "@/lib/utils"

export function AppShell() {
  const { user, signOut } = useAuth()

  return (
    <div className="min-h-screen bg-muted/30">
      <header className="border-b bg-background">
        <div className="mx-auto flex max-w-7xl items-center justify-between px-4 py-3">
          <div>
            <h1 className="text-lg font-semibold">Spare Parts Workflow</h1>
            <p className="text-xs text-muted-foreground">
              Signed in as {ROLE_LABELS[user!.role]}
            </p>
          </div>
          <Button variant="outline" size="sm" onClick={() => void signOut()}>
            <LogOut className="h-4 w-4" />
            Sign out
          </Button>
        </div>
      </header>

      <div className="mx-auto grid max-w-7xl gap-6 px-4 py-6 md:grid-cols-[240px_1fr]">
        <aside className="rounded-lg border bg-background p-2">
          <nav className="flex flex-col gap-1">
            {APP_NAV_ITEMS.filter((item) => item.allowedRoles.includes(user!.role)).map((item) => {
              const Icon = item.icon
              return (
                <NavLink
                  key={item.to}
                  to={item.to}
                  className={({ isActive }) =>
                    cn(
                      "flex items-center gap-2 rounded-md px-3 py-2 text-sm",
                      isActive ? "bg-primary text-primary-foreground" : "hover:bg-muted",
                    )
                  }
                >
                  <Icon className="h-4 w-4" />
                  {item.label}
                </NavLink>
              )
            })}
          </nav>
        </aside>

        <main className="rounded-lg border bg-background p-6">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
