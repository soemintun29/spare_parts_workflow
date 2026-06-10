import type { Session, User } from "@supabase/supabase-js"
import { type PropsWithChildren, useEffect, useMemo, useState } from "react"

import { APP_ROLES, type AppRole } from "@/config/roles"
import { AuthContext, type AuthContextValue } from "@/lib/auth-context"
import { supabase } from "@/lib/supabase"
import type { AuthenticatedUser } from "@/types/auth"

function parseRole(user: User): AppRole | null {
  const appMetaRole = user.app_metadata.role
  const userMetaRole = user.user_metadata.role
  const candidate = appMetaRole ?? userMetaRole
  return APP_ROLES.includes(candidate) ? candidate : null
}

function buildAuthenticatedUser(session: Session): AuthenticatedUser | null {
  const role = parseRole(session.user)
  if (!role) {
    return null
  }

  return {
    user: session.user,
    session,
    role,
  }
}

export function AuthProvider({ children }: PropsWithChildren) {
  const [isLoading, setIsLoading] = useState(true)
  const [user, setUser] = useState<AuthenticatedUser | null>(null)

  useEffect(() => {
    let isMounted = true

    const bootstrap = async () => {
      const { data } = await supabase.auth.getSession()
      if (!isMounted) {
        return
      }
      setUser(data.session ? buildAuthenticatedUser(data.session) : null)
      setIsLoading(false)
    }

    void bootstrap()

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      setUser(session ? buildAuthenticatedUser(session) : null)
      setIsLoading(false)
    })

    return () => {
      isMounted = false
      subscription.unsubscribe()
    }
  }, [])

  const value = useMemo<AuthContextValue>(
    () => ({
      isLoading,
      user,
      signIn: async (email, password) => {
        const { error } = await supabase.auth.signInWithPassword({ email, password })
        if (error) {
          throw error
        }
      },
      signOut: async () => {
        const { error } = await supabase.auth.signOut()
        if (error) {
          throw error
        }
      },
    }),
    [isLoading, user],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

