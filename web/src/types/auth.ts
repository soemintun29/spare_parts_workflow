import type { Session, User } from "@supabase/supabase-js"

import type { AppRole } from "@/config/roles"

export type AuthenticatedUser = {
  user: User
  session: Session
  role: AppRole
}
