local _, ns = ...

-- The shared database: counts from every /dt export merged on GitHub (tools/build_data.py). Generated, do
-- not edit; the issue workflow rebuilds it after each accepted submission.
ns.SharedBuilt = 0
