// `stream { ... yield x ... }` produces a Stream<T> that pulls lazily.
// The consumer drives it with `for ... in`; each `yield` suspends the producer
// until the next item is pulled. Cancelling the consumer drops the producer.

struct Page { offset: U64, limit: U32 }
impl Page {
    fn first() -> Page { Page { offset: 0, limit: 100 } }
    fn next(self)  -> Page { Page { offset: self.offset + self.limit, limit: self.limit } }
}

struct Batch<T> { items: List<T>, has_more: Bool, next: Page }

capability PostRepo {
    fn list(page: Page, filter: PostFilter) -> Batch<Post> raises {DbError}
}

// All-pages stream; the consumer only pays for as many posts as it pulls.
fn posts_stream(filter: PostFilter) -> Stream<Post>
    requires {PostRepo, Logger}
    raises   {DbFailure}
{
    stream {
        let mut page = Page.first()
        loop {
            let batch = try PostRepo.list(page, filter)
                catch DbError(e) -> raise DbFailure(e)
            Logger.debug("fetched page", {"offset": page.offset, "got": batch.items.len()})
            for post in batch.items { yield post }
            if !batch.has_more { break }
            page = batch.next
        }
    }
}

// Consumer side: just `for` — no awareness of paging.
fn export_first_500(filter: PostFilter) -> List<Post>
    requires {PostRepo, Logger}
    raises   {DbFailure}
{
    let mut out: List<Post> = []
    for post in posts_stream(filter) {
        out.push(post)
        if out.len() >= 500 { break }    // breaking drops the stream → producer stops
    }
    out
}
