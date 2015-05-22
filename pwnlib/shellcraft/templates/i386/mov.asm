<%
  from pwnlib.util import lists, packing, fiddling, misc
  from pwnlib import constants
  from pwnlib.context import context as ctx # Ugly hack, mako will not let it be called context
  from pwnlib.log import getLogger
  from pwnlib.shellcraft.registers import get_register, is_register, bits_required
  log = getLogger('pwnlib.shellcraft.i386.mov')
%>
<%page args="dest, src, stack_allowed = True"/>
<%docstring>
Move src into dest without newlines and null bytes.

If the src is a register smaller than the dest, then it will be
zero-extended to fit inside the larger register.

If the src is a register larger than the dest, then only some of the bits will
be used.

If src is a string that is not a register, then it will locally set
`context.arch` to `'i386'` and use :func:`pwnlib.constants.eval` to evaluate the
string. Note that this means that this shellcode can change behavior depending
on the value of `context.os`.

Example:

    >>> print shellcraft.i386.mov('eax','ebx').rstrip()
        mov eax, ebx
    >>> print shellcraft.i386.mov('eax', 0).rstrip()
        xor eax, eax
    >>> print shellcraft.i386.mov('ax', 0).rstrip()
        xor ax, ax
    >>> print shellcraft.i386.mov('ax', 17).rstrip()
        xor ax, ax
        mov al, 0x11
    >>> print shellcraft.i386.mov('edi', ord('\n')).rstrip()
        push 9 /* mov edi, '\n' */
        pop edi
        inc edi
    >>> print shellcraft.i386.mov('al', 'ax').rstrip()
        /* moving ax into al, but this is a no-op */
    >>> print shellcraft.i386.mov('al','ax').rstrip()
        /* moving ax into al, but this is a no-op */
    >>> print shellcraft.i386.mov('esp', 'esp').rstrip()
        /* moving esp into esp, but this is a no-op */
    >>> print shellcraft.i386.mov('ax', 'bl').rstrip()
        movzx ax, bl
    >>> print shellcraft.i386.mov('eax', 1).rstrip()
        push 0x1
        pop eax
    >>> print shellcraft.i386.mov('eax', 1, stack_allowed=False).rstrip()
        xor eax, eax
        mov al, 0x1
    >>> print shellcraft.i386.mov('eax', 0xdead00ff).rstrip()
        mov eax, 0x1010101 /* mov eax, 0xdead00ff */
        xor eax, 0xdfac01fe
    >>> print shellcraft.i386.mov('eax', 0xc0).rstrip()
        xor eax, eax
        mov al, 0xc0
    >>> print shellcraft.i386.mov('eax', 0xc000).rstrip()
        xor eax, eax /* mov eax, 0xc000 */
        mov ah, 0xc0
    >>> print shellcraft.i386.mov('edi', 0xc000).rstrip()
        mov edi, 0x1010101 /* mov edi, 0xc000 */
        xor edi, 0x101c101
    >>> print shellcraft.i386.mov('eax', 0xc0c0).rstrip()
        xor eax, eax
        mov ax, 0xc0c0
    >>> print shellcraft.i386.mov('eax', 'SYS_execve').rstrip()
        push 0xb
        pop eax
    >>> with context.local(os = 'freebsd'):
    ...     print shellcraft.i386.mov('eax', 'SYS_execve').rstrip()
        push 0x3b
        pop eax
    >>> print shellcraft.i386.mov('eax', 'PROT_READ | PROT_WRITE | PROT_EXEC').rstrip()
        push 0x7
        pop eax

Args:
  dest (str): The destination register.
  src (str): Either the input register, or an immediate value.
  stack_allowed (bool): Can the stack be used?
</%docstring>
<%
def okay(s):
    return '\0' not in s and '\n' not in s

def pretty(n):
    if n < 0:
        return str(n)
    else:
        return hex(n)

src_name = src
if not isinstance(src, (str, tuple)):
    src_name = pretty(src)

if not get_register(dest):
    log.error('%r is not a register' % dest)

dest = get_register(dest)

if dest.size > 32 or dest.is64bit:
    log.error("cannot use %s on i386" % dest)

if get_register(src):
    src = get_register(src)

    if src.is64bit:
        log.error("cannot use %s on i386" % src)

    if dest.size < src.size and src.name not in dest.bigger:
        log.error("cannot mov %s, %s: dddest is smaller than src" % (dest, src))
else:
    with ctx.local(arch = 'i386'):
        src = constants.eval(src)

    if not dest.fits(src):
        log.error("cannot mov %s, %r: dest is smaller than src" % (dest, src))

    src_size = bits_required(src)

    # Calculate the packed version
    srcp = packing.pack(src & ((1<<32)-1), dest.size)

    # Calculate the unsigned and signed versions
    srcu = packing.unpack(srcp, dest.size, sign=False)
    srcs = packing.unpack(srcp, dest.size, sign=True)

%>\
% if is_register(src):
    % if src == dest:
    /* moving ${src} into ${dest}, but this is a no-op */
    % elif src.name in dest.bigger:
    /* moving ${src} into ${dest}, but this is a no-op */
    % elif dest.size > src.size:
    movzx ${dest}, ${src}
    % else:
    mov ${dest}, ${src}
    % endif
% elif isinstance(src, (int, long)):
## Special case for zeroes
    % if src == 0:
        xor ${dest}, ${dest}
## Special case for *just* a newline
    % elif stack_allowed and dest.size == 32 and src == 10:
        push 9 /* mov ${dest}, '\n' */
        pop ${dest}
        inc ${dest}
## Can we push/pop it?
## This is shorter than a `mov` and has a better (more ASCII) encoding.
## Note there are two variants for PUSH IMM32 and PUSH IMM8
    % elif stack_allowed and dest.size == 32 and okay(srcp):
        push ${pretty(src)}
        pop ${dest}
    % elif stack_allowed and dest.size == 32 and  -127 <= srcs < 128 and okay(srcp[0]):
        push ${pretty(src)}
        pop ${dest}
## Easy case, everybody is happy
    % elif okay(srcp):
        mov ${dest}, ${pretty(src)}
## If it's an IMM8, we can use the 8-bit register
    % elif 0 <= srcu < 2**8 and okay(srcp[0]) and dest.sizes[8]:
        xor ${dest}, ${dest}
        mov ${dest.sizes[8]}, ${pretty(srcu)}
## If it's an IMM16, but there's nothing in the lower 8 bits,
## we can use the high-8-bits register.
## However, we must check that it exists.
    % elif srcu == (srcu & 0xff00) and okay(srcp[1]) and dest.ff00:
        xor ${dest}, ${dest} /* mov ${dest}, ${pretty(src)} */
        mov ${dest.ff00}, ${pretty(srcu >> 8)}
## If it's an IMM16, use the 16-bit register
    % elif 0 <= srcu < 2**16 and okay(srcp[:2]) and dest.sizes[16]:
        xor ${dest}, ${dest}
        mov ${dest.sizes[16]}, ${pretty(src)}
## We couldn't find a way to make things work out, so just do
## the XOR trick.
    % else:
        <%
        a,b = fiddling.xor_pair(srcp, avoid = '\x00\n')
        a = hex(packing.unpack(a, dest.size))
        b = hex(packing.unpack(b, dest.size))
        %>\
        mov ${dest}, ${a} /* mov ${dest}, ${src_name} */
        xor ${dest}, ${b}
    % endif
% endif
