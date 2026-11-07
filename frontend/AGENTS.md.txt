
# Pothole Patrol — Frontend Agent Instructions

## Project Context
Pothole Patrol is an AI-powered road damage detection and reporting application for the Indy Init 2026 hackathon.

The frontend uses React, TypeScript, and Vite.

Other teammates are responsible for the backend, computer vision models, native iOS application, and government reporting integration.

## Rules
- Work only inside `frontend/` unless explicitly instructed otherwise.
- Do not modify the native iOS app, detection models, or backend code.
- Inspect the existing code before making changes.
- Preserve existing functionality unless changes are explicitly requested.
- Keep components reusable and maintainable.
- Use TypeScript interfaces and service adapters for backend integrations.
- Use mock services when real backend APIs are unavailable.
- Never claim mock analysis or local reports are real government submissions.
- Do not create a new React or Vite project.
- Do not switch branches, merge, commit, or push without permission.

## UI Design
- Follow a professional, Samsara-inspired enterprise dashboard aesthetic.
- Prioritize clean layouts, readable typography, and responsive design.
- Optimize the resident experience for iPhone.
- Avoid generic AI-generated dashboard styling.
- Keep the official priority queue and resident map polished and functional.

## Backend Integration
- Keep API calls inside `src/services/`.
- Maintain centralized types in `src/types/`.
- Document integration contracts in `INTEGRATION.md`.
- Do not implement backend servers or AI inference directly in the frontend.

## Before Finishing
- Run `npm run build`.
- Run `npm run lint`.
- Fix errors introduced by your changes.
- Report changed files, completed features, test results, and remaining limitations.
- Do not commit or push automatically.
