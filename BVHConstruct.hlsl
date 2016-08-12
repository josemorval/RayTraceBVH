#include <BVHGlobal.hlsl>

/*
 Since BVH construction only multiplies by +/- 1 (direction), this macro computes the result
 of the multiplication using bitwise operations rather than multiplication.
 Please note that it is assumed that multiplication takes longer than the below
 operations.
 */

#define MULTIPLY_BY_POSNEG(x, s) ((x & ~(s & (s >> 1))) | ((~x + 1) & (s & (s >> 1))))

struct NODE
{
	int parent;
	int childL, childR;

	uint code;
};

struct VERTEX
{
	float3 position;
	float3 normal;
	float2 texcoord;
};

cbuffer CONSTANT_BUFFER : register(b0)
{
	int numObjects;
};

/*
DeBruijin lookup table.
The table cannot be inlined in the method
because it takes up extra local space.
*/

static const int deBruijinLookup[] =
{
	0, 31, 9, 30, 3, 8, 13, 29, 2,
	5, 7, 21, 12, 24, 28, 19,
	1, 10, 4, 14, 6, 22, 25,
	20, 11, 15, 23, 26, 16, 27, 17, 18
};

/*
Gets number of leeading zeros by representing them
as ones pushed to the right.  Does not give meaningful
number but the relative output is correct.
*/

int leadingPrefix(uint d1, uint d2)
{
	uint data = d1 ^ d2;

	data |= data >> 1;
	data |= data >> 2;
	data |= data >> 4;
	data |= data >> 8;
	data |= data >> 16;
	data++;

	// the below code will be flattened on optimization (no branch)
	return data ? deBruijinLookup[data * 0x076be629 >> 27] : 32;
}

/*
Same as leadingPrefix but does bounds checks.
*/

int leadingPrefixBounds(uint d1, int index)
{
	// the below code will be flattened on optimization (no branch)
	return (0 <= index && index < numObjects) ? leadingPrefix(d1, nodes[index].code) : -1;
}


/*
Find the children of the node.
*/

int2 getChildren(int index)
{
	uint codeCurrent = nodes[index].code;

	// get range direction
	int direction = sign(leadingPrefixBounds(codeCurrent, index + 1)
		- leadingPrefixBounds(codeCurrent, index - 1));

	// get upper bound of length range
	int minLeadingZero = leadingPrefixBounds(codeCurrent, index - direction);
	uint boundLen = 2;

	// TODO: change back to multiply by 4
	[loop]
	for (;
	minLeadingZero < leadingPrefixBounds(
		codeCurrent, index + MULTIPLY_BY_POSNEG(boundLen, direction));
	boundLen <<= 1) {
	}

	// find lower bound
	int delta = boundLen;

	int deltaSum = 0;

	[loop]
	do
	{
		delta = (delta + 1) >> 1;

		if (minLeadingZero <
			leadingPrefixBounds(
				codeCurrent, index + MULTIPLY_BY_POSNEG((deltaSum + delta), direction)))
			deltaSum += delta;
	} while (1 < delta);

	int boundStart = index + MULTIPLY_BY_POSNEG(deltaSum, direction);

	// find slice range
	int leadingZero = leadingPrefixBounds(codeCurrent, boundStart);

	delta = deltaSum;
	int tmp = 0;

	[loop]
	do
	{
		delta = (delta + 1) >> 1;

		if (leadingZero <
			leadingPrefixBounds(codeCurrent, index + MULTIPLY_BY_POSNEG((tmp + delta), direction)))
			tmp += delta;
	} while (1 < delta);

	// TODO: remove min and multiplication
	int location = index + MULTIPLY_BY_POSNEG(tmp, direction) + min(direction, 0);

	int2 children;

	if (min(index, boundStart) == location)
		children.x = location;
	else
		children.x = location + numObjects;

	if (max(index, boundStart) == location + 1)
		children.y = location + 1;
	else
		children.y = location + 1 + numObjects;

	return children;
}

[numthreads(NUM_THREADS, 1, 1)]
void main(uint3 threadID : SV_DispatchThreadID, uint groupThreadID : SV_GroupIndex, uint3 groupID : SV_GroupID)
{
	// load in the leaf nodes (load factor of 2)
	for (uint loadi = 0; loadi < 2; loadi++)
		nodes[(threadID.x << 1) + loadi].code = sortedIndex[(threadID.x << 1) + loadi];

	DeviceMemoryBarrierWithGroupSync();

	// construct the tree
	int2 children = getChildren(threadID.x);

	// set the children

	nodes[threadID.x + numObjects].childL = children.x;
	nodes[threadID.x + numObjects].childR = children.y;

	// set the parent

	nodes[children.x].parent = threadID.x + numObjects;
	nodes[children.y].parent = threadID.x + numObjects;
}