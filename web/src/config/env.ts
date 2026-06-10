import { z } from "zod"

const envSchema = z.object({
  VITE_SUPABASE_URL: z.url(),
  VITE_SUPABASE_ANON_KEY: z.string().min(1),
})

const envParse = envSchema.safeParse(import.meta.env)

if (!envParse.success) {
  // Keep this fail-fast at startup to avoid hidden auth/runtime bugs.
  throw new Error(
    `Invalid environment configuration: ${JSON.stringify(envParse.error.flatten().fieldErrors)}`,
  )
}

export const env = envParse.data
