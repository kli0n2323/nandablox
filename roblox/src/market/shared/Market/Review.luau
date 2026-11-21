-- Evidence labels and inbox ordering shared by MarketSim and the client.
local Review = {}

local labels = {
	empty_counter = "Empty counter",
	prints_displayed = "Framed prints on the counter",
	unusual_listing = "Unusual listing",
}

function Review.label(code: string?): string?
	return code and labels[code] or nil
end

function Review.evidence(case, code): string?
	if code == "empty_counter" and case.hasStock == false then
		return code
	elseif code == "prints_displayed" and case.display == "prints" then
		return code
	elseif code == "unusual_listing" then
		return code
	end
	return nil
end

function Review.before(a, b): boolean
	local aTime = a.review_at or a.deadline_at
	local bTime = b.review_at or b.deadline_at
	if aTime ~= bTime then
		return aTime < bTime
	elseif a.deadline_at ~= b.deadline_at then
		return a.deadline_at < b.deadline_at
	elseif a.created ~= b.created then
		return a.created < b.created
	end
	return a.id < b.id
end

return Review
