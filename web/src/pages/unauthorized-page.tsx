import { Link } from "react-router-dom"

export function UnauthorizedPage() {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-4 p-4 text-center">
      <h1 className="text-2xl font-semibold">Access denied</h1>
      <p className="max-w-md text-sm text-muted-foreground">
        Your account role does not have permission to access this route.
      </p>
      <Link
        to="/"
        className="inline-flex h-10 items-center rounded-md border border-input px-4 text-sm font-medium hover:bg-muted"
      >
        Back to dashboard
      </Link>
    </div>
  )
}
