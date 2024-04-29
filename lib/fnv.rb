module River
  # FNV is the Fowler–Noll–Vo hash function, a simple hash that's very easy to
  # implement, and hash the perfect characteristics for use with the 64 bits of
  # available space in a PG advisory lock.
  #
  # I'm implemented it myself so that the River gem can stay dependency free
  # (and because it's quite easy to do).
  module FNV
    def self.fnv1_hash(str, size:)
      hash = OFFSET_BASIS.fetch(size)
      mask = MASK.fetch(size)
      prime = PRIME.fetch(size)

      str.each_byte do |byte|
        hash *= prime
        hash &= mask # take lower N bits of multiplication product
        hash ^= byte
      end

      hash
    end

    MASK = {
      32 => 0xffffffff, # mask 32 bits long
      64 => 0xffffffffffffffff # mask 64 bits long
    }.freeze
    private_constant :MASK

    OFFSET_BASIS = {
      32 => 0x811c9dc5,
      64 => 0xcbf29ce484222325
    }.freeze
    private_constant :OFFSET_BASIS

    PRIME = {
      32 => 0x01000193,
      64 => 0x00000100000001B3
    }.freeze
    private_constant :PRIME
  end
end
