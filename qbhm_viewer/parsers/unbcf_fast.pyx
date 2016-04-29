import cython
import numpy as np
import sys

cdef int byte_order
if sys.byteorder == 'little':
    byte_order = 0
else:
    byte_order = 1

from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t

# fused unsigned integer type for generalised programing:

ctypedef fused channel_t:
    uint8_t
    uint16_t
    uint32_t


# instructivelly packed array structs:

cdef packed struct Bunch_head: #size 2bytes
    uint8_t size
    uint8_t channels

# endianess agnostic reading functions... probably very slow:

@cython.boundscheck(False)
cdef uint16_t read_16(unsigned char *pointer):

    return ((<uint16_t>pointer[1]<<8) & 65280) | <uint16_t>pointer[0]

@cython.boundscheck(False)
cdef uint32_t read_32(unsigned char *pointer):

    return ((<uint32_t>pointer[3]<<24) & <uint32_t>4278190080) |\
           ((<uint32_t>pointer[2]<<16) & <uint32_t>16711680) |\
           ((<uint32_t>pointer[1]<<8) & <uint32_t>65280) |\
             <uint32_t>pointer[0]

@cython.boundscheck(False)
cdef uint64_t read_64(unsigned char *pointer):
    # skiping the most high bits, as such a huge values is impossible
    # for present bruker technology. If it would change - uncomment bellow and recompile.
    #return ((<uint64_t>pointer[self.offset-1]<<24) & <uint64_t>0xff00000000000000) |\
    #   ((<uint64_t>self.buffer2[self.offset-2]<<8) & <uint64_t>0xff000000000000) |\
    #((<uint64_t>self.buffer2[self.offset-3]<<40) & <uint64_t>0xff0000000000) |\
    return ((<uint64_t>pointer[4]<<32) & <uint64_t>0xff00000000) |\
           ((<uint64_t>pointer[3]<<24) & <uint64_t>4278190080) |\
           ((<uint64_t>pointer[2]<<16) & <uint64_t>16711680) |\
           ((<uint64_t>pointer[1]<<8) & <uint64_t>65280) |\
             <uint64_t>pointer[0]


# datastream class:

@cython.boundscheck(False)
cdef class DataStream:

    cdef unsigned char *buffer2
    cdef int size, size_chnk
    cdef int offset
    cdef bytes raw_bytes
    cdef public object blocks  # public - because it is python object

    def __cinit__(self, blocks, int size_chnk):
        self.size_chnk = size_chnk
        self.size = size_chnk
        self.offset = 0

    def __init__(self, blocks, int size_chnk):
        self.blocks = blocks
        self.raw_bytes = next(self.blocks)  # python bytes buffer
        self.buffer2 = <bytes>self.raw_bytes  # C unsigned char buffer

    cdef void seek(self, int value):
        """move offset to given value.
        NOTE: it do not check if value is in bounds of buffer!"""
        self.offset = value

    cdef void skip(self, int length):
        """increase offset by given value,
        check if new offset is in bounds of buffer length
        else load up next block"""
        if (self.offset + length) > self.size:
            self.load_next_block()
        self.offset = self.offset + length

    cdef uint8_t read_8(self):
        if (self.offset + 1) > self.size:
            self.load_next_block()
        self.offset += 1
        return <uint8_t>self.buffer2[self.offset-1]

    cdef uint16_t read_16(self):
        if (self.offset + 2) > self.size:
            self.load_next_block()
        self.offset += 2
        # endianess agnostic way... probably very slow:
        return read_16(&self.buffer2[self.offset-2])

    cdef uint32_t read_32(self):
        if (self.offset + 4) > self.size:
            self.load_next_block()
        self.offset += 4
        # endianess agnostic way... probably very slow:
        return read_32(&self.buffer2[self.offset-4])

    cdef uint64_t read_64(self):
        if (self.offset + 8) > self.size:
            self.load_next_block()
        self.offset += 8
        return read_64(&self.buffer2[self.offset-8])

    cdef unsigned char *ptr_to(self, int length):
        """get the pointer to the raw buffer,
        making sure the array have the required length
        counting from the offset, increase the internal offset
        by given length"""
        if (self.offset + length) > self.size:
            self.load_next_block()
        self.offset += length
        return &self.buffer2[self.offset-length]

    cdef void load_next_block(self):
        """take the reminder of buffer (offset:end) and
        append new block of raw data, and overwrite old buffer
        handle with new, set offset to 0"""
        self.size = self.size_chnk + self.size - self.offset
        self.buffer2 = b''
        self.raw_bytes = self.raw_bytes[self.offset:] + next(self.blocks)
        self.offset = 0
        self.buffer2 = <bytes>self.raw_bytes


# function for looping throught the bcf pixels:

@cython.cdivision(True)
@cython.boundscheck(False)
cdef bin_to_numpy(DataStream data_stream,
                  channel_t[:, :, :] hypermap,
                  int max_chan,
                  int downsample,
                  int height,
                  int width):
    cdef int dummy1, line_cnt, i, j
    cdef uint32_t pix_in_line, pixel_x, add_pulse_size
    cdef uint16_t chan1, chan2, flag, data_size1, n_of_pulses, data_size2
    cdef uint16_t add_val
    for line_cnt in range(height):
        pix_in_line = data_stream.read_32()
        for dummy1 in range(pix_in_line):
            pixel_x = data_stream.read_32()
            chan1 = data_stream.read_16()
            chan2 = data_stream.read_16()
            data_stream.skip(4)  # unknown static value
            flag = data_stream.read_16()
            data_size1 = data_stream.read_16()
            n_of_pulses = data_stream.read_16()
            data_size2 = data_stream.read_16()
            data_stream.skip(2)  # skip to data
            if flag == 1:
                unpack12bit(hypermap,
                            pixel_x // downsample,
                            line_cnt // downsample,
                            data_stream.ptr_to(data_size2),
                            n_of_pulses,
                            max_chan)
            else:
                unpack_instructed(hypermap,
                                  pixel_x // downsample,
                                  line_cnt // downsample,
                                  data_stream.ptr_to(data_size2 - 4),
                                  data_size2 - 4,
                                  max_chan)
                if n_of_pulses > 0:
                    add_pulse_size = data_stream.read_32()
                    for j in range(n_of_pulses):
                        add_val = data_stream.read_16()
                        if add_val < max_chan:
                            hypermap[add_val,
                                      pixel_x // downsample,
                                      line_cnt // downsample] += 1
                else:
                    data_stream.skip(4)


#functions to extract pixel spectrum:

@cython.cdivision(True)
@cython.boundscheck(False)
cdef void unpack_instructed(channel_t[:, :, :] dest, int x, int y,
                            unsigned char * src, uint16_t data_size,
                            int cutoff):
    """
    unpack instructivelly packed delphi array into selection
    of memoryview
    """
    cdef int offset = 0
    cdef int channel = 0
    cdef int i, j, length
    cdef int gain = 0
    cdef Bunch_head* head
    cdef uint16_t val16
    cdef uint32_t val32
    while (offset < data_size):
        head =<Bunch_head*>&src[offset]
        offset +=2
        if head.size == 0:  # empty channels (zero counts)
            channel += head.channels
        else:
            if head.size == 1:
                gain = <int>(src[offset])
            elif head.size == 2:
                gain = <int>read_16(&src[offset])
            elif head.size == 4:
                gain = <int>read_32(&src[offset])
            else:
                gain = <int>read_64(&src[offset])
            offset += head.size
            if head.size == 1:  # special nibble switching case
                for i in range(head.channels):
                    if (i+channel) < cutoff:
                        #reverse the nibbles:
                        if i % 2 == 0:
                            dest[i+channel, x, y] += <channel_t>((src[offset +(i//2)] & 15) + gain)
                        else:
                            dest[i+channel, x, y] += <channel_t>((src[offset +(i//2)] >> 4) + gain)
                if head.channels % 2 == 0:
                    length = <int>(head.channels // 2)
                else:
                    length = <int>((head.channels // 2) +1)
            elif head.size == 2:
                for i in range(head.channels):
                    if (i+channel) < cutoff:
                        dest[i+channel, x, y] += <channel_t>(src[offset + i] + gain)
                length = <int>(head.channels * head.size // 2)
            elif head.size == 4:
                for i in range(head.channels):
                    if (i+channel) < cutoff:
                        val16 = read_16(&src[offset + i*2])
                        dest[i+channel, x, y] += <channel_t>(val16 + gain)
                length = <int>(head.channels * head.size // 2)
            else:
                for i in range(head.channels):
                    if (i+channel) < cutoff:
                        val32 = read_32(&src[offset + i*2])
                        dest[i+channel, x, y] += <channel_t>(val32 + gain)
                length = <int>(head.channels * head.size // 2)
            offset += length
            channel += head.channels


@cython.cdivision(True)
@cython.boundscheck(False)
cdef void unpack12bit(channel_t[:, :, :] dest, int x, int y,
                      unsigned char * src,
                      uint16_t no_of_pulses,
                      int cutoff):
    """unpack 12bit packed array into selection of memoryview"""
    cdef int i, channel
    for i in range(no_of_pulses):
        if i % 4 == 0:
            channel = <int>((src[6*(i//4)] >> 4)+(src[6*(i//4)+1] << 4))
        elif i % 4 == 1:
            channel = <int>(((src[6*(i//4)] << 8 ) + (src[6*(i//4)+3])) & 4095)
        elif i % 4 == 2:
            channel = <int>((src[6*(i//4)+2] << 4) + (src[6*(i//4)+5] >> 4))
        else:
            channel = <int>(((src[6*(i//4)+5] << 8) + src[6*(i//4)+4]) & 4095)
        if channel < cutoff:
            dest[channel, x, y] += 1

#the main function:

def parse_to_numpy(bcf, downsample=1, cutoff=None):
    blocks, block_size, total_blocks = bcf.get_iter_and_properties()
    map_depth = bcf.sfs.header.estimate_map_channels()
    if type(cutoff) == int:
        map_depth = cutoff
    dtype = bcf.sfs.header.estimate_map_depth(downsample=downsample)
    width = bcf.sfs.header.image.width
    height = bcf.sfs.header.image.height
    hypermap = np.zeros((map_depth,
                         -(-width // downsample),
                         -(-height // downsample)),
                         dtype=dtype)
    cdef DataStream data_stream = DataStream(blocks, block_size)
    data_stream.seek(0x1A0)
    if dtype == np.uint8:
        bin_to_numpy[uint8_t](data_stream, hypermap, map_depth, downsample,
                              height, width)
        return hypermap
    elif dtype == np.uint16:
        bin_to_numpy[uint16_t](data_stream, hypermap, map_depth, downsample,
                              height, width)
        return hypermap
    elif dtype == np.uint32:
        bin_to_numpy[uint32_t](data_stream, hypermap, map_depth, downsample,
                              height, width)
        return hypermap
    else:
        raise NotImplementedError('64bit array not implemented!')


def parse_in_chunks(bcf, heights=[], downsample=1, cutoff=None):
    """return iterator to parse the bcf in chunks

    The atomicity of chunks is the line of pixels. Thus for reading the
    bcf in chunks, list of line intervals have to be provided.
    It is also possible to provide downsample factor, but the
    care should be taken that intervals in height list would be dividable
    by downsample ratio:

    i.e. having the hypermap of 2048*2048, we want to downsample by
    factor 3. in 4 chunks. while 2048 / 4 = nice round 512, it is not
    divisible by 3, thus the chunk line number should be enlarged to 513
    which is divisable by 3. finaly it would look like this. Else there
    would be artifacts between merged chunks. Thus in this case it should
    look like this:
    >> parse_in_chunks(some_bcf, heights=[513, 513, 513, 509], downsample = 3)
    """
    blocks, block_size, total_blocks = bcf.get_iter_and_properties()
    cdef DataStream data_stream = DataStream(blocks, block_size)
    data_stream.seek(0x1A0)
    map_depth = bcf.sfs.header.estimate_map_channels()
    if type(cutoff) == int:
        map_depth = cutoff
    dtype = bcf.sfs.header.estimate_map_depth(downsample=downsample)
    width = bcf.sfs.header.image.width
    for height in heights:
        hypermap = np.zeros((map_depth, width, height),
                            dtype=dtype)
        if dtype == np.uint8:
            bin_to_numpy[uint8_t](data_stream, hypermap, map_depth, downsample,
                                  height, width)
            yield hypermap
        elif dtype == np.uint16:
            bin_to_numpy[uint16_t](data_stream, hypermap, map_depth, downsample,
                                  height, width)
            yield hypermap
        elif dtype == np.uint32:
            bin_to_numpy[uint32_t](data_stream, hypermap, map_depth, downsample,
                                  height, width)
            yield hypermap
        else:
            raise NotImplementedError('64bit array not implemented!')
