---
title: "Using JSON to filter on lists in MySQL"
date: 2022-10-16T15:39:00+02:00
draft: true
---

Filtering a column on a list of values in MySQL can be cumbersome, often
requiring the user to dynamically create queries at runtime using `IN (...)`.

In this post I will explain my problem with this approach, how other SQL
databases solve this and how you can (ab)use JSON support in MySQL to solve
this problem.

<!--more-->

## The problem

In MySQL when filtering on a list of values most users will use the `IN (...)`
operator by creating a dynamic list of values (or placeholders).

For example to filter for products with ID 1, 3 or 7 most users would generate
a query like this:

```sql
SELECT * FROM products WHERE id IN (1, 3, 7)
```

If you want to add another ID to the list, you then need to regenerate the
whole query:


```sql
SELECT * FROM products WHERE id IN (1, 3, 7, 9)
```

Doing this manually for each query with a filter lik this can be cumbersome.

While this can be abstracted away, and most ORMs and helper libraries will
gladly do so, this can still become annoying when having to manually write
queries.

Even worse this can hurt performance since it makes it harder to reuse prepared
statements as you would need a prepared statement for each list length.

The question is: Can we do better? To answer this, let's first look at how
other SQL databases handle this.

## Filtering on lists in other databases

Some other SQL databases like PostgreSQL have native support for
[arrays](https://www.postgresql.org/docs/current/arrays.html) which can be used
in order to filter a value based on a list.

For example, the following query which is valid in MySQL and PostgreSQL

```sql
SELECT * FROM products WHERE id IN (1, 2, 3, 4, 5)
```

can be written like this in PostgreSQL

```sql
SELECT * FROM products WHERE id = ANY(ARRAY[1, 2, 3, 4, 5])
```

At a first glance this may not seem like much of an improvement.
But there is an important advantage over the naive `IN (...)` based query.

First let's substitute the values in the first query with placeholders.

```sql
SELECT * FROM products WHERE id IN (?, ?, ?, ?, ?)
```

Or for PostgreSQL

```sql
SELECT * FROM products WHERE id IN ($1, $2, $3, $4, $5)
```

Unlinke MySQL which uses _?_ for placeholders, in PostgreSQL placeholders are
specified in the form _$N_ where _N_ is the 1-based index of the parameter that
will be passed to the query.

Now let's do the same thing with the second (PostgreSQL only) query.

```sql
SELECT * FROM products WHERE id = ANY($1)
```

Can you see it now?

Arrays are first-class citizens in PostgreSQL and can be passed as a **single**
parameter.

When using `IN (...)` each value needs its own placeholder which, as discussed
before, requires creating the query dynamically based on the number of
values in the list.

On the other hand, by using first-class arrays in PostgreSQL we only need to
create and prepare a single statement which we can use for all executions, no
matter how many values we have to filter on.

This can make a big difference in performance. And as an added bonus, this also
handles empty lists correctly, where as writing `IN ()` would be a syntax error
and thus needs to be handled manually in the client.

Unfortunately since MySQL does not have support for arrays, we have to find
another way to improve our lifes.

## JSON to the rescue

Starting with version 5.7.8 MySQL has begun adding native support for JSON
values. This ranges from validating JSON over querying it and even updating
JSON values.

Unlike MySQL, JSON supports arrays and MySQLs JSON functions and operators
can work with arrays too.

We can use this to our advantage to improve how we do our list filters.

## Member of

With JSON support in MySQL a new operator was introduced: `MEMBER OF ()`.

As the name may have given aways already the `MEMBER OF ()` operator checks
if a value exists in a JSON array. Basically `MEMBER OF ()` works like `IN ()`
but instead of operating on a fixed list of values it works with a JSON array.

Let's look the the previous example query and see how it could look like when
using the `MEMBER OF ()` operator.

```sql
SELECT * FROM products WHERE id IN (1, 2, 3, 4, 5)
```

And now using `MEMBER OF ()`:

```sql
SELECT * FROM products WHERE id MEMBER OF ('[1, 2, 3, 4, 5]')
```

Not much of a difference. We replaced the list of values with a string
containing a JSON array and changed the `IN` to `MEMBER OF`.

Running both queries, the result _should be_ exactly the same.

The big difference becomes visible when we begin using placeholders.

```sql
SELECT * FROM products WHERE id MEMBER OF (?)
```

The array has become a single placeholder. Just as with native arrays in
PostgreSQL, we now only have a single parameter, which means we no longer have
to generate a query per number of items in the list and can instead use (and
reuse) a single query / prepared statement!

Also like native arrays this correctly handles the case where we have an
empty list!

Unfortunately there is a "small" problem: It doesn't work.

The `MEMBER OF ()` operator expects the left operand to be a JSON value and
will not match anything if the value has any other type.

So in order for this to work we would need to cast our ID to JSON like this:

```sql
SELECT * FROM products WHERE CAST(id AS JSON) MEMBER OF (?)
```

This will return the correct results. But there is still a problem: Performance.

### Considerations: Generating the JSON

Before we look at how this approach performs in practice let's quickly discuss
another "problem" with using JSON for our input: In order to use this approach
we need to be able to generate JSON on the client.

This means we need some kind of library that supports generating JSON.

Fortunately most programing languages and frameworks already come with upport
for generating JSON out of the box.

Another consideration is the time it takes to generate the JSON. While this
will differ between programming languages / frameworks, in general the overhead
of generating JSON from some list that already exists in memory should be
negligible and most modern JSON libraries that exist are highly optimized.

Also, though you should avoid this when possible, if you know that you have a
list that only contains integers (because you have a type system that enforces
this) you can simply generate the JSON array by doing something like this:

```javascript
"[" + values.join(",") + "]"
```

### Performance

The query plan for the previous query looks like this:

{{<table>}}
| select\_type | type | possible\_keys | key | key\_len | ref | Extra |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| SIMPLE | null | ALL | null | null | null | Using where |
{{</table>}}

I omitted the uninteresting fields.

We can see that MySQL wants to do a full table scan even though the ID is the
primary key for this table. The reason is that we casted the ID which prevents
the use of any indices.

In theory we could try using functional indices or generated columns to work
around this, but one of my goals was to find a solution that would not need
any changes to the schema.

Given this constraint it looks like using `MEMBER OF ()` will not get us what
we want.

But that does not mean that there is no other way to solve the problem!

## Using JSON_TABLE

There is another interesting way to use JSON for filtering: `JSON_TABLE`.

The `JSON_TABLE` function allows declaring a virtual table based on JSON data
which can be used like any other ordinary table.

Let's assume that we have the following JSON:

```json
[
    {
        "firstName": "Joe",
        "lastName": "Doe"
    },
    {
        "firstName": "Jane",
        "lastName": "Doe"
    }
]
```

Using `JSON_TABLE` we can directly query this JSON, either from a row stored in
MySQL or directly from a query or parameter.

```sql
SELECT * FROM JSON_TABLE(
    ?, -- the JSON
    '$[*]'
    COLUMNS (
        first_name VARCHAR(32) PATH '$.firstName',
        last_name VARCHAR(32) PATH '$.lastName'
    )
) AS t
```

This will return the following data:

{{<table>}}
| first_name | last_name |
| ---------- | --------- |
| Joe        | Doe       |
| Jane       | Doe       |
{{</table>}}

See the [documentation](https://dev.mysql.com/doc/refman/8.0/en/json-table-functions.html)
for more information on `JSON_TABLE`.

Now let's see how we can apply this for our problem.

### Using a subselect

Instead of using `IN (...)` with fixed values it is possible to put a subselect
into the `IN (...)`. By using `JSON_TABLE` we can directly filter for the
values from our JSON.

```sql
SELECT *
FROM products
WHERE id IN (
    SELECT * FROM JSON_TABLE(
        ?,
        '$[*]' COLUMNS (
            id INT PATH '$'
        )
    ) AS t
)
```

This will work as expected, though it may not look very nice.

Fortunately there there is another way to use `JSON_TABLE` that is
in my opinion more readable and works for most cases where `IN (...)` is used.

### Using JOIN

Instead of using a subselect it is also possible to `JOIN` on the result of
`JSON_TABLE` just like any other table which.

```sql
SELECT *
FROM products
INNER JOIN JSON_TABLE(
    ?,
    '$[*]' COLUMNS (
        id INT PATH '$'
    )
) AS t ON t.id = products.id
```

This is often simpler and, as we see later, sometimes faster than using
subselects (and in some cases even faster than using `IN (...)` with fixed
values / placeholders).

**TODO: Revisit this once benchmarks are done**

### Performance comparison

In order to see how good the JSON based solutions performan I wrote a simple
benchmark that would execute a select against a table with ~61k rows, selecting
a single non-indexes column by primary key (integer) using a list of 10 random
IDs from the table.

Each query was executed 2500 times and the time for each batch of 2500
aggregated and the average time was calculated (using [benchstat](https://pkg.go.dev/golang.org/x/perf/benchstat)
tool, 20 runs per query).

This is the result:

{{<table>}}
| Type      | Milliseconds |
| --------- | ------------ |
| IN        |  911         |
| Subselect | 1090         |
| JOIN      | 1010         |
{{</table>}}

As you can see there is some overhead to using `JSON_TABLE`, more so with
subselects.

The reason for this is that there is some overhead to parsing the JSON and
converting it into a virtual table.
The more rows we query, that is the more values our `IN (...)` or JSON array
contain, the smaller the difference.

**TODO: Revisit this once benchmarks are done**

### Advantages of using JOIN

Using a `JOIN` instead of `IN (...)` has some other advantages.

#### Multiple conditions

Our example used an array of scalar values for our JSON array, but `JSON_TABLE`
can work with any valid JSON. This allows for more complex joins.

Lets use this JSON again:

```json
[
    {
        "firstName": "Joe",
        "lastName": "Doe"
    },
    {
        "firstName": "Jane",
        "lastName": "Doe"
    }
]
```

With this we could do something like this:

```sql
SELECT *
FROM persons
INNER JOIN JSON_TABLE(
    ?, -- the JSON
    '$[*]'
    COLUMNS (
        first_name VARCHAR(32) PATH '$.firstName',
        last_name VARCHAR(32) PATH '$.lastName'
    )
) AS t ON t.first_name = persons.first_name
      AND t.last_name = persons.last_name
```

This filters on 2 columns instead of only one. We could also get more creative
and do other operators than `=` but this shall suffice as an example.

Note that this example could also be written without JSON and using `IN (...)`
with tuples like this:

```sql
(first_name, last_name) IN (('Jane', 'Doe'), ('John', 'Doe'))
```

But again we have the problem that we need to generate a query for each set of
inputs.

Also while this technically works, the optimizer will most likely not use any
index for this, thogu that may change with newer MySQL versions.

#### Returning rows in list order

Normally when using `JSON_TABLE` (or `IN (...)`) the rows will be returned in
arbitrary order unless you use `ORDER BY`. But what if you want the rows to be
returned in the same order as the values in the list?

`JSON_TABLE` offers a neat little feature that can help achieve this. The
feature is called `FOR ORDINALITY`.

Defining a columns as `FOR ORDINALITY` means that the column will contain the
0-based index of the value in the JSON array. This can then be used to sort
by the index.

Here is an example:

```sql
SELECT *
FROM products
INNER JOIN JSON_TABLE('[1,3,5]', '$[*]' COLUMNS (
    ord FOR ORDINALITY,
    id INT PATH '$'
)) AS t ON t.id = products.id
ORDER BY t.ord
```

This will ensure that the products are always returned in the given order (in
this case frst 1, then 3 and then 5).

### Disadvantages

#### Complex filters

While using an `INNER JOIN` in place of `IN (...)` will often just work, this
may not always be the case. Depending on the query you may need a `LEFT JOIN`
or, if this is not feasible, fall back to either a sub-select or
`MEMBER OF ()`.

#### Support for JSON_TABLE

While `JSON_TABLE` can be a great way for filtering rows, some third party
tools that use or wrap MySQL, like Vitess or PlanetScale (which uses Vitess
under the hood) may not support `JSON_TABLE` yet.

**TODO: Revisit this once benchmarks are done**

### Values Table

An alternative to using JSON and `JSON_TABLE` is using [`VALUES`](https://dev.mysql.com/doc/refman/8.0/en/values.html)
to create a table from fixed values.

For example filtering on an ID could look like this:

```sql
SELECT products.*
FROM products
INNER JOIN (
    VALUES
        ROW(1),
        ROW(3),
        ROW(7)
) AS v ON v.column_0 = id
```

While this may avoid the (negligible) overhead of parsing JSON and converting
it into a table, it suffers from the same problem as `IN (...)` in that the
query needs to be generated for each number of values in the list.

When the number of values in the list is static this can be a good alternative
to `IN (...)` since the JOIN will most likely be faster, but if the number of
values is not fixed, using JSON will likely be easier.

## Conclusion

Oracle, *please* add support for [arrays](https://www.postgresql.org/docs/current/arrays.html)
to MySQL!

And while you are at it, please also add support for
[RETURNING](https://www.postgresql.org/docs/current/dml-returning.html), and
[partial indexes](https://www.postgresql.org/docs/current/indexes-partial.html).

Until then, the best solution (at least in my opinion) is using `JSON_TABLE`.

