import { Navigate, Outlet } from "react-router-dom"

import type { AppRole } from "@/config/roles"
import { useAuth } from "@/hooks/use-auth"

type RoleRouteProps = {
  allowedRoles: AppRole[]
}

export function RoleRoute({ allowedRoles }: RoleRouteProps) {
  const { user } = useAuth()

  if (!user) {
    return <Navigate to="/login" replace />
  }

  if (!allowedRoles.includes(user.role)) {
    return <Navigate to="/unauthorized" replace />
  }

  return <Outlet />
}
