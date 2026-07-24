# Partitioning

For very large datasets, or very high query throughput, replication is not sufficient: we
need to break the data up into partitions, also known as sharding. The main reason for
wanting to partition data is scalability. Different partitions can be placed on different
nodes in a shared-nothing cluster, so a large dataset can be distributed across many disks,
and the query load can be distributed across many processors.

## Partitioning by key range

One way of partitioning is to assign a continuous range of keys to each partition. If you
know the boundaries between the ranges, you can determine which partition contains a given
key. The ranges of keys are not necessarily evenly spaced, because your data may not be
evenly distributed. In order to distribute the data evenly, the partition boundaries need
to adapt to the data.

## Partitioning by hash of key

Because of the risk of skew and hot spots, many distributed datastores use a hash function
to determine the partition for a given key. A good hash function takes skewed data and makes
it uniformly distributed. Once you have a suitable hash function for keys, you can assign each
partition a range of hashes, and every key whose hash falls within a partition's range is
stored in that partition.
