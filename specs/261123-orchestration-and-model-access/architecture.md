# Architecture

```mermaid
flowchart TB
  subgraph writers
    API[afs-api as afs_app]
    REC[afs-reconciler]
    GW[afs-gateway]
    EDGE[afs-edge as afs_edge]
  end
  API -->|create_orchestration_agent, updates| TC[(team_collaboration<br/>tool, web_ui_exposure, web_api_exposure)]
  API --> AG[(agents / agent_pools<br/>model_access, default_model_id)]
  API --> AM[(agent_models / pool_models)]
  ADM[service admin] --> TL[(teams.max_collaboration_exposure<br/>teams.model_access)]
  ADM --> ST[(service_settings<br/>orchestration.*, models.*)]
  TC -->|BEFORE triggers: sync, limit, profile| TC
  TL --> OR[orchestration_routes]
  ST --> OR
  TC --> OR
  OR --> EDGE
  AM --> V[effective_agent_models / model_admission]
  TL --> V
  ST --> V
  V --> GW
  V --> REC
  REC --> TIP[(team_inference_profiles)]
```

Checks at write time (constraint names in `data-dictionary.md`) are `BEFORE` triggers; checks that need several rows in a transaction (required orchestration agent, non-empty selection, default inside the selection, tool and template agreement) are deferred constraint triggers, checked at commit.

The edge never reads a table: it calls `orchestration_routes()` and `orchestration_settings()`, `SECURITY DEFINER` functions with a pinned `search_path`.
