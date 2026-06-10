import { createContext } from "react"

import type { AuthenticatedUser } from "@/types/auth"

export type AuthContextValue = {
  isLoading: boolean
  user: AuthenticatedUser | null
  signIn: (email: string, password: string) => Promise<void>
  signOut: () => Promise<void>
}

export const AuthContext = createContext<AuthContextValue | undefined>(undefined)
