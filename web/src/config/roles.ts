export const APP_ROLES = [
  "technician",
  "warehouse_controller",
  "dispatcher",
  "service_manager",
  "finance_admin",
] as const

export type AppRole = (typeof APP_ROLES)[number]

export const ROLE_LABELS: Record<AppRole, string> = {
  technician: "Technician",
  warehouse_controller: "Warehouse Controller",
  dispatcher: "Dispatcher",
  service_manager: "Service Manager",
  finance_admin: "Finance/Admin",
}
