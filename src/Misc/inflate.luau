-- ReplicatedStorage/Misc/inflate.luau
--!strict
--!optimize 2
--!native

-- DEFLATE decompression (RFC 1951, raw — no zlib/gzip wrapper).
--
-- Roblox has no built-in decompressor, and baked map chunks are shipped deflated
-- (doc 23): ~21% of their raw size, which is the difference between a map that
-- fits in a place and one that doesn't. Records are small (a chunk is ~2.4 KB out
-- of ~540 B in), so this is called once per chunk with a known output size and
-- never has to be fast — only correct.
--
-- Structure follows zlib's `puff` reference decoder: canonical Huffman decoding by
-- walking code lengths, which is compact and easy to verify, rather than the
-- multi-level lookup tables a throughput-oriented decoder would use.

local Inflate = {}

local MAXBITS = 15

-- Length codes 257..285: base length + extra bits.
local LEN_BASE = {
	3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
	67, 83, 99, 115, 131, 163, 195, 227, 258,
}
local LEN_EXTRA = {
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
	4, 4, 4, 4, 5, 5, 5, 5, 0,
}
-- Distance codes 0..29: base distance + extra bits.
local DIST_BASE = {
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
	1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}
local DIST_EXTRA = {
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
	9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}
-- The order code-length code lengths are stored in.
local CLEN_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

type Huffman = { counts: { number }, symbols: { number } }

-- Build a canonical Huffman table from code lengths (lengths[1..n], 0 = unused).
-- `counts[len + 1]` holds how many codes have length `len`; `symbols` lists the
-- symbols sorted by code length, then by symbol — which is what makes the decoder
-- below a simple walk.
local function construct(lengths: { number }, n: number): Huffman
	local counts = table.create(MAXBITS + 1, 0)
	for i = 1, n do
		local l = lengths[i]
		counts[l + 1] += 1
	end
	counts[1] = 0 -- length 0 means "no code", not "a code of length 0"

	local offs = table.create(MAXBITS + 1, 0) -- offs[len] = where length `len` starts
	for len = 1, MAXBITS - 1 do
		offs[len + 1] = offs[len] + counts[len + 1]
	end

	local symbols = table.create(n, 0)
	for i = 1, n do
		local l = lengths[i]
		if l ~= 0 then
			symbols[offs[l] + 1] = i - 1 -- symbols are 0-based
			offs[l] += 1
		end
	end
	return { counts = counts, symbols = symbols }
end

-- Decompress `src` (raw deflate) into a buffer of exactly `outSize` bytes.
function Inflate.raw(src: buffer, outSize: number): buffer
	local out = buffer.create(outSize)
	local srcLen = buffer.len(src)

	local pos = 0 -- next byte to read
	local bitbuf = 0
	local bitcnt = 0
	local outPos = 0

	local function bits(need: number): number
		while bitcnt < need do
			if pos >= srcLen then
				error("inflate: ran out of input")
			end
			bitbuf = bit32.bor(bitbuf, bit32.lshift(buffer.readu8(src, pos), bitcnt))
			pos += 1
			bitcnt += 8
		end
		local v = bit32.band(bitbuf, bit32.lshift(1, need) - 1)
		bitbuf = bit32.rshift(bitbuf, need)
		bitcnt -= need
		return v
	end

	local function decode(h: Huffman): number
		local counts, symbols = h.counts, h.symbols
		local code, first, index = 0, 0, 0
		for len = 1, MAXBITS do
			code = bit32.bor(code, bits(1))
			local count = counts[len + 1]
			if code - first < count then
				return symbols[index + (code - first) + 1]
			end
			index += count
			first = bit32.lshift(first + count, 1)
			code = bit32.lshift(code, 1)
		end
		error("inflate: invalid Huffman code")
	end

	-- Fixed tables are built once, lazily (most streams here use dynamic ones).
	local fixedLit: Huffman? = nil
	local fixedDist: Huffman? = nil
	local function fixedTables(): (Huffman, Huffman)
		if not fixedLit then
			local l = table.create(288, 0)
			for i = 1, 144 do l[i] = 8 end
			for i = 145, 256 do l[i] = 9 end
			for i = 257, 280 do l[i] = 7 end
			for i = 281, 288 do l[i] = 8 end
			fixedLit = construct(l, 288)
			local d = table.create(30, 5)
			fixedDist = construct(d, 30)
		end
		return fixedLit :: Huffman, fixedDist :: Huffman
	end

	local function codes(lit: Huffman, dist: Huffman)
		while true do
			local sym = decode(lit)
			if sym < 256 then
				buffer.writeu8(out, outPos, sym)
				outPos += 1
			elseif sym == 256 then
				return -- end of block
			else
				sym -= 256
				if sym > 29 then
					error("inflate: invalid length code")
				end
				local len = LEN_BASE[sym] + bits(LEN_EXTRA[sym])
				local dsym = decode(dist) + 1
				if dsym > 30 then
					error("inflate: invalid distance code")
				end
				local d = DIST_BASE[dsym] + bits(DIST_EXTRA[dsym])
				if d > outPos then
					error("inflate: distance reaches before the output")
				end
				local from = outPos - d
				for i = 0, len - 1 do
					buffer.writeu8(out, outPos + i, buffer.readu8(out, from + i))
				end
				outPos += len
			end
		end
	end

	repeat
		local last = bits(1)
		local btype = bits(2)
		if btype == 0 then
			-- Stored block: skip to the byte boundary. Whole bytes already pulled
			-- into the bit buffer have to be handed BACK to `pos`, not thrown away.
			pos -= bitcnt // 8
			bitbuf, bitcnt = 0, 0
			local len = buffer.readu8(src, pos) + buffer.readu8(src, pos + 1) * 256
			pos += 4 -- skip LEN and NLEN
			buffer.copy(out, outPos, src, pos, len)
			outPos += len
			pos += len
		elseif btype == 1 then
			codes(fixedTables())
		elseif btype == 2 then
			local nlen = bits(5) + 257
			local ndist = bits(5) + 1
			local ncode = bits(4) + 4

			local clens = table.create(19, 0)
			for i = 1, ncode do
				clens[CLEN_ORDER[i] + 1] = bits(3)
			end
			local clenTable = construct(clens, 19)

			local lengths = table.create(nlen + ndist, 0)
			local i = 1
			while i <= nlen + ndist do
				local sym = decode(clenTable)
				if sym < 16 then
					lengths[i] = sym
					i += 1
				else
					local value, repeats
					if sym == 16 then
						if i == 1 then
							error("inflate: repeat with no previous length")
						end
						value = lengths[i - 1]
						repeats = 3 + bits(2)
					elseif sym == 17 then
						value = 0
						repeats = 3 + bits(3)
					else
						value = 0
						repeats = 11 + bits(7)
					end
					for _ = 1, repeats do
						lengths[i] = value
						i += 1
					end
				end
			end

			local litLens = table.create(nlen, 0)
			table.move(lengths, 1, nlen, 1, litLens)
			local distLens = table.create(ndist, 0)
			table.move(lengths, nlen + 1, nlen + ndist, 1, distLens)
			codes(construct(litLens, nlen), construct(distLens, ndist))
		else
			error("inflate: reserved block type")
		end
	until last == 1

	if outPos ~= outSize then
		error(`inflate: produced {outPos} bytes, expected {outSize}`)
	end
	return out
end

return Inflate
