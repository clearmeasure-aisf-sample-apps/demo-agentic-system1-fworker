// Work intake (issue 104, Invoke-Intake in plugin/scripts/lib/Verbs.Sweep.ps1): the sweep pulls the next work item from Todo onto the board in Technical Design when a
// worker slot is free and nothing waits there. The rule script decides what to pull; the gateway says how many owner sessions could take a new
// work item now. A slot is free on a connected owner session that is not draining, not cooling down after missed offers, not spent (one item per
// session: it held or was offered a work item) and has less owned items and open own-item offers than its capacity. In memory, like the plant.
sealed partial class Plant
{
    public int IntakeSlots()
    {
        lock (gate)
        {
            var free = 0;
            foreach (var w in workers.Values)
            {
                if (!w.Connected || w.Draining || !w.Roles.Contains("owner") || Cooling(w)) continue;
                if (OneItemPerSession && w.SessionItems.Count > 0) continue;
                // the load as Choose counts it (owned items, bot jobs, open offers, and the slots a waiting pin claims), and the host's limit
                var load = Owned(w.Name) + PinnedWaiting(w.Name);
                if (OneItemPerSession && load > 0) continue;
                if (!HostHasRoom(w.Name)) continue;
                free += Math.Max(0, w.Capacity - load);
            }
            return free;
        }
    }
}
