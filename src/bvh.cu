#include "bvh.h"

// BBox class
BBox::BBox() : minC(glm::vec3(INF_F)), maxC(glm::vec3(-INF_F))
{
	extent = maxC - minC;
}

BBox::BBox(const glm::vec3& p) : minC(p), maxC(p)
{
	extent = maxC - minC;
}

BBox::BBox(const glm::vec3 min, const glm::vec3 max) : minC(min), maxC(max), extent(max - min) {}

BBox::BBox(const BBox& bbox) : minC(bbox.minC), maxC(bbox.maxC), extent(extent) {}

BBox& BBox::operator=(const BBox& bbox)
{
	minC = bbox.minC;
	maxC = bbox.maxC;
	extent = bbox.extent;

	return *this;
}

void BBox::expand(const BBox& bbox) 
{
	minC.x = std::min(minC.x, bbox.minC.x);
	minC.y = std::min(minC.y, bbox.minC.y);
	minC.z = std::min(minC.z, bbox.minC.z);
	maxC.x = std::max(maxC.x, bbox.maxC.x);
	maxC.y = std::max(maxC.y, bbox.maxC.y);
	maxC.z = std::max(maxC.z, bbox.maxC.z);
	extent = maxC - minC;
}

void BBox::expand(const glm::vec3& p)
{
	minC.x = std::min(minC.x, p.x);
	minC.y = std::min(minC.y, p.y);
	minC.z = std::min(minC.z, p.z);
	maxC.x = std::max(maxC.x, p.x);
	maxC.y = std::max(maxC.y, p.y);
	maxC.z = std::max(maxC.z, p.z);
	extent = maxC - minC;
}

glm::vec3 BBox::centroid() const
{
	return (minC + maxC) / 2.0f;
}

float BBox::surfaceArea() const
{
	if (empty())
	{
		return 0.0f;
	}
	else 
	{
		return 2 * (extent.x * extent.z + extent.x * extent.y + extent.y * extent.z);
	}
}

bool BBox::empty() const
{
	return minC.x > maxC.x || minC.y > maxC.y || minC.z > maxC.z;
}

__device__ bool BBox::intersect(const Ray& r, double& t0, double& t1) const
{
	glm::vec3 testMinC = minC;
	double tXMin = (minC.x - r.origin.x) / r.direction.x;
	double tXMax = (maxC.x - r.origin.x) / r.direction.x;
	if (tXMax < tXMin)
	{
		double tmp = tXMin;
		tXMin = tXMax;
		tXMax = tmp;
	}

	double tYMin = (minC.y - r.origin.y) / r.direction.y;
	double tYMax = (maxC.y - r.origin.y) / r.direction.y;
	if (tYMax < tYMin)
	{
		double tmp = tYMin;
		tYMin = tYMax;
		tYMax = tmp;
	}

	double tZMin = (minC.z - r.origin.z) / r.direction.z;
	double tZMax = (maxC.z - r.origin.z) / r.direction.z;
	if (tZMax < tZMin)
	{
		double tmp = tZMin;
		tZMin = tZMax;
		tZMax = tmp;
	}

	double tmin = fmaxf(fmaxf(tXMin, tYMin), tZMin);
	double tmax = fminf(fminf(tXMax, tYMax), tZMax);

	if (tmin > tmax)
	{
		return false;
	}

	if ((tmin >= t0) && (tmax <= t1))
	{
		t0 = tmin;
		t1 = tmax;
	}

	return (t0 < r.tmax) && (t1 > r.tmin);
}

// BVHNode class
BVHNode::BVHNode(BBox bbox) : bb(bbox), leftNodeIndex(-1), rightNodeIndex(-1), p1I(-1), p2I(-1), p3I(-1), p4I(-1) {}

BVHNode::BVHNode(const BVHNode& node) 
{
	bb = node.bb;
	leftNodeIndex = node.leftNodeIndex;
	rightNodeIndex = node.rightNodeIndex;
	p1I = node.p1I;
	p2I = node.p2I;
	p3I = node.p3I;
	p4I = node.p4I;
}

BVHNode& BVHNode::operator=(const BVHNode& node)
{
	if (this != &node) 
	{
		bb = node.bb;
		leftNodeIndex = node.leftNodeIndex;
		rightNodeIndex = node.rightNodeIndex;
		p1I = node.p1I;
		p2I = node.p2I;
		p3I = node.p3I;
		p4I = node.p4I;
	}

	return *this;
}

void BVHNode::setPrims(const std::vector<int>& pI) 
{
	int pSize = pI.size();

	if (pSize >= 1) 
	{
		p1I = pI[0];
	}

	if (pSize >= 2)
	{
		p2I = pI[1];
	}

	if (pSize >= 3)
	{
		p3I = pI[2];
	}

	if (pSize == 4)
	{
		p4I = pI[3];
	}
}

__device__ bool BVHNode::isLeaf() const
{
	return p1I >= 0;
}

// BVH Construction Helper
BBox getBBox(const Primitive& prim) 
{
	if (prim.type == TRIANGLE) 
	{
		BBox bbox(prim.p1);
		bbox.expand(prim.p2);
		bbox.expand(prim.p3);
		return bbox;
	}
	else if (prim.type == SPHEREP)
	{
		return BBox(prim.p2, prim.p3);
	}
	else if (prim.type == CUBEP)
	{
		return BBox(prim.p2, prim.p3);
	}
}

int findSplitAxis(glm::vec3 cen) 
{
	int axis;

	if (cen.x >= cen.y)
	{
		if (cen.x >= cen.z)
		{
			axis = 0;
		}
		else
		{
			axis = 2;
		}
	}
	else
	{
		if (cen.y >= cen.z)
		{
			axis = 1;
		}
		else
		{
			axis = 2;
		}
	}

	return axis;
}

// Construct the BVH for the primitives with indices in primsIndices, store the BVHNodes in bvhs, and return the index of the root BVHNode
int constructBVH(const std::vector<Primitive>& prims, const std::vector<int>& primsIndices, std::vector<BVHNode>& bvh, size_t maxLeafSize)
{
	// Populate all primitives
	BBox cetroidBox, bbox;
	for (int i : primsIndices)
	{
		BBox bb = getBBox(prims[i]);
		bbox.expand(bb);
		cetroidBox.expand(bb.centroid());
	}

	// Construct root BVHNode
	BVHNode node(bbox);
	int curIndex = bvh.size();
	bvh.push_back(node);

	if (primsIndices.size() <= maxLeafSize)
	{
		bvh[curIndex].setPrims(primsIndices);
	}
	else 
	{
		int axis = findSplitAxis(cetroidBox.extent);
		float splitPoint = cetroidBox.centroid()[axis];

		double left = 0, right = 0;
		std::vector<int> leftIndices, rightIndices;

		while (leftIndices.empty() || rightIndices.empty()) 
		{
			for (int j : primsIndices)
			{
				float pCentroidAxis = getBBox(prims[j]).centroid()[axis];

				if (pCentroidAxis >= splitPoint) 
				{
					rightIndices.push_back(j);
					right += pCentroidAxis;
				}
				else 
				{
					leftIndices.push_back(j);
					left += pCentroidAxis;
				}
			}

			if (leftIndices.empty()) 
			{
				splitPoint = right / rightIndices.size();
				right = 0;
				rightIndices.clear();
			}
			else if (rightIndices.empty())
			{
				splitPoint = left / leftIndices.size();
				left = 0;
				leftIndices.clear();
			}
			else 
			{
				bvh[curIndex].rightNodeIndex = constructBVH(prims, rightIndices, bvh);
				bvh[curIndex].leftNodeIndex = constructBVH(prims, leftIndices, bvh);
			}
		}
	}
	return curIndex;
}

__device__ bool intersectBVH(Ray& ray, ShadeableIntersection& intersection, Geom* geoms, Primitive* prims, BVHNode* bvh, int cur)
{
	BVHNode& node = bvh[cur];

	glm::vec3 testBBmin = node.bb.minC;
	glm::vec3 testBBmax = node.bb.maxC;
	int testl = node.leftNodeIndex;
	int testr = node.rightNodeIndex;
	int testP1 = node.p1I;
	int testP2 = node.p2I;
	int testP3 = node.p3I;
	int testP4 = node.p4I;

	double t0 = ray.tmin, t1 = ray.tmax;
	if (!node.bb.intersect(ray, t0, t1))
	{
		return false;
	}

	if (node.isLeaf()) 
	{
		bool hit = false;
		
		int primIndices[4] = { node.p1I, node.p2I, node.p3I, node.p4I };

		for (int i = 0; i < 4; i++) 
		{
			if (primIndices[i] > -1) 
			{
				int pId = primIndices[i];
				Primitive& p = prims[pId];
				bool curHit = false;

				if (p.type == TRIANGLE)
				{
					curHit = triangleIntersection(geoms[p.geomId], p, ray, intersection);
				}
				else if (p.type == CUBEP)
				{
					curHit = boxIntersection(geoms[p.geomId], p, ray, intersection);
				}
				else if (p.type == SPHEREP)
				{
					curHit = sphereIntersection(geoms[p.geomId], p, ray, intersection);
				}

				if (curHit)
				{
					hit = true;
					intersection.primitiveId = primIndices[i];
					intersection.materialId = geoms[p.geomId].materialid;
				}
			}
		}
		/*if (testP1 > -1) {
			Primitive& p = prims[testP1];
			bool curHit = false;

			if (p.type == TRIANGLE)
			{
				curHit = triangleIntersection(geoms[p.geomId], p, ray, intersection);
			}
			else if (p.type == CUBEP)
			{
				curHit = boxIntersection(geoms[p.geomId], p, ray, intersection);
			}
			else if (p.type == SPHEREP)
			{
				curHit = sphereIntersection(geoms[p.geomId], p, ray, intersection);
			}

			if (curHit)
			{
				hit = true;
				intersection.primitiveId = testP1;
				intersection.materialId = geoms[p.geomId].materialid;
			}
		}

		if (testP2 > -1) {
			Primitive& p = prims[testP2];
			bool curHit = false;

			if (p.type == TRIANGLE)
			{
				curHit = triangleIntersection(geoms[p.geomId], p, ray, intersection);
			}
			else if (p.type == CUBEP)
			{
				curHit = boxIntersection(geoms[p.geomId], p, ray, intersection);
			}
			else if (p.type == SPHEREP)
			{
				curHit = sphereIntersection(geoms[p.geomId], p, ray, intersection);
			}

			if (curHit)
			{
				hit = true;
				intersection.primitiveId = testP2;
				intersection.materialId = geoms[p.geomId].materialid;
			}
		}

		if (testP3 > -1) {
			Primitive& p = prims[testP3];
			bool curHit = false;

			if (p.type == TRIANGLE)
			{
				curHit = triangleIntersection(geoms[p.geomId], p, ray, intersection);
			}
			else if (p.type == CUBEP)
			{
				curHit = boxIntersection(geoms[p.geomId], p, ray, intersection);
			}
			else if (p.type == SPHEREP)
			{
				curHit = sphereIntersection(geoms[p.geomId], p, ray, intersection);
			}

			if (curHit)
			{
				hit = true;
				intersection.primitiveId = testP3;
				intersection.materialId = geoms[p.geomId].materialid;
			}
		}

		if (testP4 > -1) {
			Primitive& p = prims[testP4];
			bool curHit = false;

			if (p.type == TRIANGLE)
			{
				curHit = triangleIntersection(geoms[p.geomId], p, ray, intersection);
			}
			else if (p.type == CUBEP)
			{
				curHit = boxIntersection(geoms[p.geomId], p, ray, intersection);
			}
			else if (p.type == SPHEREP)
			{
				curHit = sphereIntersection(geoms[p.geomId], p, ray, intersection);
			}

			if (curHit)
			{
				hit = true;
				intersection.primitiveId = testP4;
				intersection.materialId = geoms[p.geomId].materialid;
			}
		}*/


		
		return hit;
	}
	else 
	{
		bool interL = intersectBVH(ray, intersection, geoms, prims, bvh, node.leftNodeIndex);
		bool interR = intersectBVH(ray, intersection, geoms, prims, bvh, node.rightNodeIndex);
		return interL || interR;
	}
}