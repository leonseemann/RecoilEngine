/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "System/Platform/CpuTopology.h"

#include <sys/sysctl.h>
#include <sys/types.h>

namespace cpu_topology {

static uint32_t SysctlU32(const char* name, uint32_t def = 0) {
	uint64_t v64 = 0; size_t len = sizeof(v64);
	if (sysctlbyname(name, &v64, &len, nullptr, 0) != 0)
		return def;
	if (len == sizeof(uint32_t)) {
		uint32_t v32; __builtin_memcpy(&v32, &v64, sizeof(v32));
		return v32;
	}
	return static_cast<uint32_t>(v64);
}

static uint32_t MakeMask(uint32_t first, uint32_t count) {
	uint32_t mask = 0;
	for (uint32_t i = first; i < first + count && i < 32; ++i)
		mask |= (1u << i);
	return mask;
}

ThreadPinPolicy GetThreadPinPolicy() {
	return THREAD_PIN_POLICY_NONE;
}

ProcessorMasks GetProcessorMasks() {
	ProcessorMasks masks;
	const uint32_t numLevels = SysctlU32("hw.nperflevels", 1);
	const uint32_t total = SysctlU32("hw.logicalcpu", 1);

	if (numLevels <= 1) {
		masks.performanceCoreMask = MakeMask(0, total);
		return masks;
	}
	const uint32_t perf = SysctlU32("hw.perflevel0.logicalcpu", total);
	const uint32_t eff  = SysctlU32("hw.perflevel1.logicalcpu", 0);
	// cpu ids are not ordered by perf level; masks are only used as counts
	masks.performanceCoreMask = MakeMask(0, perf);
	masks.efficiencyCoreMask  = MakeMask(perf, eff);
	return masks;
}

ProcessorCaches GetProcessorCache() {
	ProcessorCaches caches;
	ProcessorGroupCaches group;
	group.groupMask = MakeMask(0, SysctlU32("hw.logicalcpu", 1));
	group.cacheSizes[0] = SysctlU32("hw.l1dcachesize");
	group.cacheSizes[1] = SysctlU32("hw.l2cachesize");
	group.cacheSizes[2] = SysctlU32("hw.l3cachesize");
	caches.groupCaches.push_back(group);
	return caches;
}

}
