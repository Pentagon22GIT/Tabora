#import "TaboraMachOSymbolResolver.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/vm_prot.h>
#import <stdint.h>
#import <string.h>

static BOOL TSLCheckedAddUInt64(
    uint64_t lhs,
    uint64_t rhs,
    uint64_t *result
) {
    if (UINT64_MAX - lhs < rhs) {
        return NO;
    }
    *result = lhs + rhs;
    return YES;
}

static BOOL TSLRangeIsWithin(
    uint64_t start,
    uint64_t length,
    uint64_t containerStart,
    uint64_t containerLength
) {
    uint64_t end = 0;
    uint64_t containerEnd = 0;
    return TSLCheckedAddUInt64(start, length, &end)
        && TSLCheckedAddUInt64(
            containerStart,
            containerLength,
            &containerEnd
        )
        && start >= containerStart
        && end <= containerEnd;
}

static const struct mach_header_64 *TSLFindImage(
    const char *imagePath,
    intptr_t *slide
) {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index += 1) {
        const char *loadedPath = _dyld_get_image_name(index);
        if (loadedPath && strcmp(loadedPath, imagePath) == 0) {
            *slide = _dyld_get_image_vmaddr_slide(index);
            return (const struct mach_header_64 *)
                _dyld_get_image_header(index);
        }
    }
    return NULL;
}

static BOOL TSLSymbolIsInExecutableSegment(
    const struct mach_header_64 *header,
    uint64_t symbolValue
) {
    const uint8_t *cursor = (const uint8_t *)header
        + sizeof(struct mach_header_64);
    const uint8_t *commandsEnd = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index += 1) {
        if (cursor + sizeof(struct load_command) > commandsEnd) {
            return NO;
        }
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)
            || cursor + command->cmdsize > commandsEnd) {
            return NO;
        }
        if (command->cmd == LC_SEGMENT_64
            && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            uint64_t end = 0;
            if (TSLCheckedAddUInt64(segment->vmaddr, segment->vmsize, &end)
                && symbolValue >= segment->vmaddr
                && symbolValue < end) {
                return (segment->initprot & VM_PROT_EXECUTE) != 0;
            }
        }
        cursor += command->cmdsize;
    }
    return NO;
}

void * _Nullable TSLResolveLocalMachOSymbol(
    const char *imagePath,
    const char *symbolName,
    TSLMachOSymbolResolutionStatus * _Nullable status
) {
    if (status) {
        *status = TSLMachOSymbolResolutionStatusMalformedImage;
    }
    if (!imagePath || !symbolName) {
        return NULL;
    }

    intptr_t slide = 0;
    const struct mach_header_64 *header = TSLFindImage(imagePath, &slide);
    if (!header) {
        if (status) *status = TSLMachOSymbolResolutionStatusImageMissing;
        return NULL;
    }
    if (header->magic != MH_MAGIC_64) {
        if (status) *status = TSLMachOSymbolResolutionStatusUnsupportedImage;
        return NULL;
    }

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const uint8_t *cursor = (const uint8_t *)header
        + sizeof(struct mach_header_64);
    const uint8_t *commandsEnd = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index += 1) {
        if (cursor + sizeof(struct load_command) > commandsEnd) {
            if (status) *status =
                TSLMachOSymbolResolutionStatusMalformedImage;
            return NULL;
        }
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)
            || cursor + command->cmdsize > commandsEnd) {
            if (status) *status =
                TSLMachOSymbolResolutionStatusMalformedImage;
            return NULL;
        }
        if (command->cmd == LC_SEGMENT_64
            && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, SEG_LINKEDIT, 16) == 0) {
                linkedit = segment;
            }
        } else if (command->cmd == LC_SYMTAB
                   && command->cmdsize >= sizeof(struct symtab_command)) {
            symtab = (const struct symtab_command *)command;
        }
        cursor += command->cmdsize;
    }
    if (!linkedit) {
        if (status) *status = TSLMachOSymbolResolutionStatusLinkeditMissing;
        return NULL;
    }
    if (!symtab) {
        if (status) *status =
            TSLMachOSymbolResolutionStatusSymbolTableMissing;
        return NULL;
    }

    uint64_t symbolBytes = 0;
    if (__builtin_mul_overflow(
        (uint64_t)symtab->nsyms,
        (uint64_t)sizeof(struct nlist_64),
        &symbolBytes
    )
        || !TSLRangeIsWithin(
            symtab->symoff,
            symbolBytes,
            linkedit->fileoff,
            linkedit->filesize
        )
        || !TSLRangeIsWithin(
            symtab->stroff,
            symtab->strsize,
            linkedit->fileoff,
            linkedit->filesize
        )) {
        if (status) *status = TSLMachOSymbolResolutionStatusMalformedImage;
        return NULL;
    }

    uintptr_t linkeditBase = (uintptr_t)slide
        + (uintptr_t)linkedit->vmaddr
        - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *symbols =
        (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    for (uint32_t index = 0; index < symtab->nsyms; index += 1) {
        const struct nlist_64 entry = symbols[index];
        if ((entry.n_type & N_STAB) != 0
            || (entry.n_type & N_TYPE) == N_UNDF
            || entry.n_value == 0
            || entry.n_un.n_strx >= symtab->strsize) {
            continue;
        }
        const char *candidate = strings + entry.n_un.n_strx;
        size_t remaining = symtab->strsize - entry.n_un.n_strx;
        if (!memchr(candidate, '\0', remaining)) {
            if (status) *status =
                TSLMachOSymbolResolutionStatusMalformedImage;
            return NULL;
        }
        if (strcmp(candidate, symbolName) != 0) {
            continue;
        }
        if (!TSLSymbolIsInExecutableSegment(header, entry.n_value)) {
            if (status) *status =
                TSLMachOSymbolResolutionStatusSymbolNotExecutable;
            return NULL;
        }
        if (status) *status = TSLMachOSymbolResolutionStatusResolved;
        return (void *)((uintptr_t)entry.n_value + (uintptr_t)slide);
    }

    if (status) *status = TSLMachOSymbolResolutionStatusSymbolMissing;
    return NULL;
}

NSString *TSLMachOSymbolResolutionStatusDescription(
    TSLMachOSymbolResolutionStatus status
) {
    switch (status) {
        case TSLMachOSymbolResolutionStatusResolved:
            return @"resolved";
        case TSLMachOSymbolResolutionStatusImageMissing:
            return @"image missing";
        case TSLMachOSymbolResolutionStatusUnsupportedImage:
            return @"unsupported Mach-O image";
        case TSLMachOSymbolResolutionStatusLinkeditMissing:
            return @"__LINKEDIT missing";
        case TSLMachOSymbolResolutionStatusSymbolTableMissing:
            return @"LC_SYMTAB missing";
        case TSLMachOSymbolResolutionStatusMalformedImage:
            return @"malformed Mach-O bounds";
        case TSLMachOSymbolResolutionStatusSymbolMissing:
            return @"exact local symbol missing";
        case TSLMachOSymbolResolutionStatusSymbolNotExecutable:
            return @"symbol is outside executable segment";
    }
    return @"unknown resolver status";
}
