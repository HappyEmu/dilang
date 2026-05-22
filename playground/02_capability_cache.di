// Declaring a capability, writing two impls, and choosing one at the wiring site.
//
// `Cache<K, V>` is a generic capability with two methods. The production impl
// is an LRU; the test impl is a plain map. Neither leaks into the call site —
// `use_cache` just lists `requires {Cache<Str, User>}`.

struct User { id: Uuid, name: Str }

capability Cache<K, V> @ Process
    where K: Eq + Hash
{
    fn get(key: K) -> V?
    fn put(key: K, val: V)
}

// Production: bounded LRU.
struct LruCache<K, V> { capacity: U32, /* ... */ }

impl<K, V> Cache<K, V> for LruCache<K, V>
    where K: Eq + Hash
{
    requires {Clock}    // used internally to stamp entries for eviction

    fn get(key: K) -> V? { /* ... */ }
    fn put(key: K, val: V) { /* ... */ }
}

// Test: unbounded map, no Clock dependency.
struct MapCache<K, V> { entries: Mutex<Map<K, V>> }

impl<K, V> Cache<K, V> for MapCache<K, V>
    where K: Eq + Hash
{
    requires {IO}    // for the Mutex

    fn get(key: K) -> V? { self.entries.lock(|m| m.get(key)) }
    fn put(key: K, val: V) { self.entries.lock(|m| m.insert(key, val)) }
}

fn lookup_user(id: Str) -> User?
    requires {Cache<Str, User>, UserRepo}
    raises   {DbFailure}
{
    Cache.get(id) ?? {
        let user = UserRepo.find_by_external_id(id) ?? return None
        Cache.put(id, user)
        user
    }
}
