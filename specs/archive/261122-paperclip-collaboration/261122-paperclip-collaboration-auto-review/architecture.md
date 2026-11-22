# Architecture: paperclip-collaboration-auto-review
Unchanged from the parent spec. Each fix is a function body change in migration 000020; guards stay SECURITY DEFINER (or INVOKER where they key on `current_user`, ADR-010). The down migration drops the same objects, so it is unchanged.
