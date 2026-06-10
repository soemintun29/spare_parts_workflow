import type { LucideIcon } from "lucide-react"
import {
  ClipboardList,
  HandCoins,
  LayoutDashboard,
  Package,
  Truck,
  Users,
} from "lucide-react"

import type { AppRole } from "@/config/roles"

export type AppNavItem = {
  to: string
  label: string
  icon: LucideIcon
  allowedRoles: AppRole[]
}

export const APP_NAV_ITEMS: AppNavItem[] = [
  {
    to: "/",
    label: "Dashboard",
    icon: LayoutDashboard,
    allowedRoles: [
      "technician",
      "warehouse_controller",
      "dispatcher",
      "service_manager",
      "finance_admin",
    ],
  },
  {
    to: "/requests",
    label: "Part Requests",
    icon: ClipboardList,
    allowedRoles: [
      "technician",
      "warehouse_controller",
      "dispatcher",
      "service_manager",
    ],
  },
  {
    to: "/inventory",
    label: "Inventory",
    icon: Package,
    allowedRoles: ["warehouse_controller", "service_manager"],
  },
  {
    to: "/transfers",
    label: "Transfers",
    icon: Truck,
    allowedRoles: [
      "technician",
      "warehouse_controller",
      "dispatcher",
      "service_manager",
    ],
  },
  {
    to: "/sales",
    label: "Cash Sales",
    icon: HandCoins,
    allowedRoles: ["warehouse_controller", "service_manager", "finance_admin"],
  },
  {
    to: "/team",
    label: "Team View",
    icon: Users,
    allowedRoles: ["dispatcher", "service_manager"],
  },
]
