--[[
* UberMap - fuzzy label matching for the search box.
*
* Kept free of Ashita/D3D dependencies so it can be exercised outside the game
* by test_search.lua.  Both arguments are expected already lower-cased: the
* caller folds case once per search rather than once per label.
--]]

local M = { };

--[[
* Edit distance from the whole of q to the closest run of s, so a query is
* allowed to sit anywhere in a label: "ronfar" is one edit from a run of "east
* ronfaure" even though the two strings as a whole are miles apart.
*
* The Levenshtein table with a free first row (Sellers): starting anywhere in s
* costs nothing, and the answer is the cheapest cell of the last row, which
* ends the match anywhere.  Two letters typed the wrong way round cost one edit
* rather than two (Damerau's transposition), since that is the typo people
* actually make -- "jueno" is meant to reach Jeuno.
*
* Only the two rows above the current one are ever read, so three arrays are
* kept and rotated rather than the whole table.
--]]
function M.distance(q, s)
    local nq, ns = #q, #s;
    if (nq == 0) then
        return 0;
    end
    local prev2, prev, cur = { }, { }, { };
    for j = 0, ns do
        prev[j], prev2[j] = 0, 0;
    end
    for i = 1, nq do
        cur[0] = i;                               -- dropping all of q so far
        local qc = q:sub(i, i);
        local qp = q:sub(i - 1, i - 1);
        for j = 1, ns do
            local sc = s:sub(j, j);
            local d = prev[j - 1] + ((qc == sc) and 0 or 1);
            local up = prev[j] + 1;               -- a letter typed that is not there
            if (up < d) then d = up; end
            local left = cur[j - 1] + 1;          -- a letter of the label missed out
            if (left < d) then d = left; end
            if (i > 1 and j > 1 and qc == s:sub(j - 1, j - 1) and qp == sc) then
                local swap = prev2[j - 2] + 1;    -- the two typed the wrong way round
                if (swap < d) then d = swap; end
            end
            cur[j] = d;
        end
        prev2, prev, cur = prev, cur, prev2;
    end
    local best = prev[0];
    for j = 1, ns do
        if (prev[j] < best) then
            best = prev[j];
        end
    end
    return best;
end

--[[
* How many edits a query of this length is allowed to be out by.  Three letters
* and under get none: at that length a single edit reaches most of the map, and
* the whole point of typing is to narrow it.  Two is the cap however long the
* query runs, for the same reason.
--]]
function M.tolerance(q)
    local n = #q;
    if (n < 4) then
        return 0;
    end
    if (n < 7) then
        return 1;
    end
    return 2;
end

--[[
* True while s answers q.  Spelling is only forgiven when fuzzy is set, which
* the caller decides once for the whole map: a query that already names
* something as typed is taken at its word, so "norg" finds Norg rather than
* every Nor- zone one edit away from it.
--]]
function M.match(q, s, fuzzy)
    local tol = fuzzy and M.tolerance(q) or 0;
    if (tol == 0) then
        return s:find(q, 1, true) ~= nil;
    end
    return M.distance(q, s) <= tol;
end

return M;
