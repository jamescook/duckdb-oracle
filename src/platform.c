// Small platform helpers that are simpler to write in C than in Zig.
#ifndef _WIN32
#define _GNU_SOURCE // dladdr
#endif
#include <stddef.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>

// Full path of the oci.dll that is loaded into this process (UTF-8), or 0.
size_t duckdb_oracle_oci_library_path(char *buf, size_t buflen) {
	HMODULE mod = GetModuleHandleW(L"oci.dll");
	if (!mod || buflen == 0) {
		return 0;
	}
	wchar_t wbuf[MAX_PATH * 4];
	DWORD n = GetModuleFileNameW(mod, wbuf, (DWORD)(sizeof(wbuf) / sizeof(wbuf[0])));
	if (n == 0) {
		return 0;
	}
	int len = WideCharToMultiByte(CP_UTF8, 0, wbuf, (int)n, buf, (int)buflen - 1, NULL, NULL);
	if (len <= 0) {
		return 0;
	}
	buf[len] = 0;
	return (size_t)len;
}

static const char *machine_name(USHORT m) {
	switch (m) {
	case 0x8664: return "x64";
	case 0xAA64: return "arm64";
	case 0x014C: return "x86";
	case 0x01C4: return "arm";
	default: return "unknown";
	}
}

// Architecture of the machine (not of this process): under x64 emulation on
// Windows ARM64 this still reports "arm64". Uses IsWow64Process2 (Windows 10
// 1709+) resolved at run time so no new import is needed; falls back to
// GetNativeSystemInfo.
size_t duckdb_oracle_host_arch(char *buf, size_t buflen) {
	typedef BOOL(WINAPI * fn_t)(HANDLE, USHORT *, USHORT *);
	const char *name = NULL;
	HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
	fn_t fn = k32 ? (fn_t)(void *)GetProcAddress(k32, "IsWow64Process2") : NULL;
	USHORT pm = 0, nm = 0;
	if (fn && fn(GetCurrentProcess(), &pm, &nm)) {
		name = machine_name(nm);
	} else {
		SYSTEM_INFO si;
		GetNativeSystemInfo(&si);
		switch (si.wProcessorArchitecture) {
		case PROCESSOR_ARCHITECTURE_AMD64: name = "x64"; break;
		case PROCESSOR_ARCHITECTURE_ARM64: name = "arm64"; break;
		case PROCESSOR_ARCHITECTURE_INTEL: name = "x86"; break;
		default: name = "unknown"; break;
		}
	}
	size_t len = strlen(name);
	if (len >= buflen) return 0;
	memcpy(buf, name, len + 1);
	return len;
}

// First oci.dll found with the standard search path (UTF-8 path) and the
// architecture from its PE header ("x64", "arm64", "x86", ...). 0 if none.
size_t duckdb_oracle_find_oci(char *path, size_t pathlen, char *arch, size_t archlen) {
	wchar_t wbuf[MAX_PATH * 4];
	DWORD n = SearchPathW(NULL, L"oci.dll", NULL, (DWORD)(sizeof(wbuf) / sizeof(wbuf[0])), wbuf, NULL);
	if (n == 0 || n >= sizeof(wbuf) / sizeof(wbuf[0]) || pathlen == 0 || archlen == 0) return 0;
	const char *aname = "unknown";
	HANDLE h = CreateFileW(wbuf, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
	if (h != INVALID_HANDLE_VALUE) {
		unsigned char hdr[4096];
		DWORD got = 0;
		if (ReadFile(h, hdr, sizeof(hdr), &got, NULL) && got >= 64 && hdr[0] == 'M' && hdr[1] == 'Z') {
			DWORD off = (DWORD)hdr[0x3C] | ((DWORD)hdr[0x3D] << 8) | ((DWORD)hdr[0x3E] << 16) | ((DWORD)hdr[0x3F] << 24);
			if (off + 6 <= got && hdr[off] == 'P' && hdr[off + 1] == 'E') {
				aname = machine_name((USHORT)(hdr[off + 4] | (hdr[off + 5] << 8)));
			}
		}
		CloseHandle(h);
	}
	int len = WideCharToMultiByte(CP_UTF8, 0, wbuf, (int)n, path, (int)pathlen - 1, NULL, NULL);
	if (len <= 0) return 0;
	path[len] = 0;
	size_t al = strlen(aname);
	if (al >= archlen) al = archlen - 1;
	memcpy(arch, aname, al);
	arch[al] = 0;
	return (size_t)len;
}

// Environment variable as UTF-8. Returns 1 if set; *out_len = UTF-8 length.
// Copies with a NUL terminator when buf has room for out_len + 1 bytes.
int duckdb_oracle_getenv(const char *name, char *buf, size_t buflen, size_t *out_len) {
	wchar_t wname[256];
	int wn = MultiByteToWideChar(CP_UTF8, 0, name, -1, wname, 256);
	if (wn <= 0) return 0;
	DWORD need = GetEnvironmentVariableW(wname, NULL, 0); // includes NUL
	if (need == 0) return 0;
	wchar_t *wval = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, need * sizeof(wchar_t));
	if (!wval) return 0;
	DWORD got = GetEnvironmentVariableW(wname, wval, need);
	int len = got ? WideCharToMultiByte(CP_UTF8, 0, wval, (int)got, NULL, 0, NULL, NULL) : 0;
	if (got == 0 && need > 1) { HeapFree(GetProcessHeap(), 0, wval); return 0; }
	*out_len = (size_t)len;
	if (buf && buflen > (size_t)len) {
		if (len > 0) WideCharToMultiByte(CP_UTF8, 0, wval, (int)got, buf, len, NULL, NULL);
		buf[len] = 0;
	}
	HeapFree(GetProcessHeap(), 0, wval);
	return 1;
}

#else
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/utsname.h>

// Full path of the libclntsh that is loaded into this process, or 0.
size_t duckdb_oracle_oci_library_path(char *buf, size_t buflen) {
	if (buflen == 0) {
		return 0;
	}
	void *handle = dlopen("libclntsh.so", RTLD_LAZY | RTLD_NOLOAD);
	if (!handle) {
		return 0;
	}
	void *sym = dlsym(handle, "OCIClientVersion");
	size_t len = 0;
	Dl_info info;
	if (sym && dladdr(sym, &info) && info.dli_fname) {
		len = strlen(info.dli_fname);
		if (len >= buflen) {
			len = buflen - 1;
		}
		memcpy(buf, info.dli_fname, len);
		buf[len] = 0;
	}
	dlclose(handle);
	return len;
}
size_t duckdb_oracle_host_arch(char *buf, size_t buflen) {
	struct utsname u;
	if (uname(&u) != 0) return 0;
	const char *name = u.machine;
	if (strcmp(name, "x86_64") == 0) name = "x64";
	else if (strcmp(name, "aarch64") == 0) name = "arm64";
	size_t len = strlen(name);
	if (len >= buflen) return 0;
	memcpy(buf, name, len + 1);
	return len;
}

// Not needed on Linux (libclntsh is resolved by the dynamic loader).
size_t duckdb_oracle_find_oci(char *path, size_t pathlen, char *arch, size_t archlen) {
	(void)path; (void)pathlen; (void)arch; (void)archlen;
	return 0;
}
int duckdb_oracle_getenv(const char *name, char *buf, size_t buflen, size_t *out_len) {
	const char *v = getenv(name);
	if (!v) return 0;
	size_t len = strlen(v);
	*out_len = len;
	if (buf && buflen > len) {
		memcpy(buf, v, len + 1);
	}
	return 1;
}
#endif
