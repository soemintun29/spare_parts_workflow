# Spare Parts Workflow Web

Frontend foundation for the Spare Parts Operation Workflow project.

## Stack
- React + Vite + TypeScript
- Supabase (Auth integration foundation)
- React Query
- Tailwind CSS
- Zod

## Getting Started
1. Install dependencies:
   - `npm install`
2. Configure environment variables:
   - copy `.env.example` to `.env`
   - set `VITE_SUPABASE_URL`
   - set `VITE_SUPABASE_ANON_KEY`
3. Run development server:
   - `npm run dev`

## Quality Gates
- `npm run lint`
- `npm run typecheck`
- `npm run check`

## Current Phase Coverage
Phase 1 foundation includes:
- auth/session provider and login form
- role-based route guards and navigation shell
- baseline protected pages for workflow modules
