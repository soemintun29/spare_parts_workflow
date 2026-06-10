import { Navigate, Outlet, useLocation } from "react-router-dom"

import type { AppRole } from "@/config/roles"
import { useAuth } from "@/hooks/use-auth"

type GuardedRouteProps = {
  allowedRoles?: AppRole[]
}

export function GuardedRoute({ allowedRoles }: GuardedRouteProps) {
  const location = useLocation()
  const { isLoading, user } = useAuth()

  if (isLoading) {
    return <div className="p-6 text-sm text-muted-foreground">Loading session...</div>
  }

  if (!user) {
    return <Navigate to="/login" replace state={{ from: location }} />
  }

  if (allowedRoles && !allowedRoles.includes(user.role)) {
    return <Navigate to="/unauthorized" replace />
  }

  return <Outlet />
}
