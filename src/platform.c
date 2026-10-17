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

// --- Client locator adapter (src/client_locator.zig) ------------------------
// All paths cross this interface as UTF-8; the wide-character Win32 API is used
// throughout, so directory names with non-ASCII characters work.

static int utf8_to_wide(const char *in, wchar_t *out, size_t cap) {
	int n = MultiByteToWideChar(CP_UTF8, 0, in, -1, out, (int)cap);
	return n > 0;
}

// Architecture ("x64", "arm64", "x86", ...) from the PE header of `utf8_path`,
// NULL when the file cannot be opened. "unknown" for a file that is not a PE image.
const char *duckdb_oracle_file_arch(const char *utf8_path) {
	wchar_t wpath[MAX_PATH * 4];
	if (!utf8_to_wide(utf8_path, wpath, sizeof(wpath) / sizeof(wpath[0]))) return NULL;
	HANDLE h = CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
	                       FILE_ATTRIBUTE_NORMAL, NULL);
	if (h == INVALID_HANDLE_VALUE) return NULL;
	const char *aname = "unknown";
	unsigned char hdr[4096];
	DWORD got = 0;
	if (ReadFile(h, hdr, sizeof(hdr), &got, NULL) && got >= 64 && hdr[0] == 'M' && hdr[1] == 'Z') {
		DWORD off = (DWORD)hdr[0x3C] | ((DWORD)hdr[0x3D] << 8) | ((DWORD)hdr[0x3E] << 16) | ((DWORD)hdr[0x3F] << 24);
		if (off + 6 <= got && hdr[off] == 'P' && hdr[off + 1] == 'E') {
			aname = machine_name((USHORT)(hdr[off + 4] | (hdr[off + 5] << 8)));
		}
	}
	CloseHandle(h);
	return aname;
}

// Load a library by full path. LOAD_WITH_ALTERED_SEARCH_PATH makes Windows look
// for the library's own dependencies (oraociei*.dll, ...) in its directory.
// Returns 1 on success, else 0 with the Win32 error in *err.
int duckdb_oracle_load_library(const char *utf8_path, unsigned long *err) {
	wchar_t w[MAX_PATH * 4], full[MAX_PATH * 4];
	if (!utf8_to_wide(utf8_path, w, sizeof(w) / sizeof(w[0]))) {
		*err = ERROR_INVALID_NAME;
		return 0;
	}
	DWORD n = GetFullPathNameW(w, (DWORD)(sizeof(full) / sizeof(full[0])), full, NULL);
	if (n == 0 || n >= sizeof(full) / sizeof(full[0])) {
		*err = ERROR_FILENAME_EXCED_RANGE;
		return 0;
	}
	// no "missing DLL" message box on a headless or service host
	UINT old_mode = SetErrorMode(SEM_FAILCRITICALERRORS);
	HMODULE m = LoadLibraryExW(full, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
	DWORD last = GetLastError();
	SetErrorMode(old_mode);
	if (!m) {
		*err = last;
		return 0;
	}
	return 1;
}

static size_t module_dir_utf8(HMODULE mod, char *buf, size_t buflen) {
	wchar_t w[MAX_PATH * 4];
	DWORD n = GetModuleFileNameW(mod, w, (DWORD)(sizeof(w) / sizeof(w[0])));
	if (n == 0 || n >= sizeof(w) / sizeof(w[0]) || buflen == 0) return 0;
	while (n > 0 && w[n - 1] != L'\\' && w[n - 1] != L'/') n--;
	if (n == 0) return 0;
	n--; // drop the separator
	int len = WideCharToMultiByte(CP_UTF8, 0, w, (int)n, buf, (int)buflen - 1, NULL, NULL);
	if (len <= 0) return 0;
	buf[len] = 0;
	return (size_t)len;
}

// Directory this extension (the DLL containing this function) was loaded from.
size_t duckdb_oracle_module_dir(char *buf, size_t buflen) {
	HMODULE mod = NULL;
	if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
	                        (LPCWSTR)(void *)&duckdb_oracle_module_dir, &mod))
		return 0;
	return module_dir_utf8(mod, buf, buflen);
}

// Directory of the host executable (duckdb.exe).
size_t duckdb_oracle_app_dir(char *buf, size_t buflen) {
	return module_dir_utf8(NULL, buf, buflen);
}

// Convert UTF-8 to the ANSI code page (the encoding ODPI-C's LoadLibraryA wants).
// Returns 1 only if the conversion is lossless.
int duckdb_oracle_utf8_to_ansi(const char *in, char *out, size_t outlen) {
	wchar_t w[MAX_PATH * 4];
	if (!utf8_to_wide(in, w, sizeof(w) / sizeof(w[0]))) return 0;
	BOOL used_default = FALSE;
	int n = WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, w, -1, out, (int)outlen, NULL, &used_default);
	return n > 0 && !used_default;
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
