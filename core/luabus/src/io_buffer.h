﻿
#pragma once

#include <assert.h>
#include <limits.h>
#include <string.h>

constexpr int IO_BUFFER_DEF		= 16 * 1024;             //16K
constexpr int IO_BUFFER_MAX		= 64 * 1024 * 1024;		 //64M
constexpr int IO_BUFFER_SEND	= 8 * 1024;
constexpr size_t IO_ALIGN_SIZE	= 128;					 //水位(2M)

class io_buffer
{
public:
	io_buffer() { alloc_buffer(IO_BUFFER_DEF); }
	~io_buffer() { free(m_buffer); }

	size_t resize(size_t size, bool align = false)
	{
		regularize();
		size_t data_len = (size_t)(m_data_end - m_data_begin);
		if (size == m_buffer_size || size < data_len || size > IO_BUFFER_MAX) {
			return m_buffer_end - m_data_end;
		}
		m_buffer = (BYTE*)realloc(m_buffer, size);
		m_data_end = m_buffer + data_len;
		m_data_begin = m_buffer;
		m_buffer_size = size;
		m_buffer_end = m_buffer + m_buffer_size;
		if (align) {
			m_align_size = size;
			m_align_max = m_align_size * IO_ALIGN_SIZE;
		}
		return m_buffer_size - data_len;
	}

	bool push_data(const void* data, size_t data_len)
	{
		size_t space_len;
		peek_space(&space_len, data_len);
		if (space_len < data_len) {
			return false;
		}		
		memcpy(m_data_end, data, data_len);
		m_data_end += data_len;
		return true;
	}

	void pop_data(size_t uLen)
	{
		assert(m_data_begin + uLen <= m_data_end);
		m_data_begin += uLen;
		size_t data_len = (size_t)(m_data_end - m_data_begin);
		if (m_buffer_size > m_align_max && data_len < m_align_size)	{
			resize(m_buffer_size / 2);
		} else if (data_len == 0) {
			regularize();
		}
	}

	void clear()
	{
		resize(m_align_size);
		m_buffer_size = m_align_size;
		m_data_begin = m_data_end = m_buffer;
	}

	BYTE* peek_space(size_t* len,size_t want_len = 0)
	{
		size_t space_len = m_buffer_end - m_data_end;
		want_len = want_len == 0 ? (m_align_size / 4) : want_len;
		if (space_len < want_len) {
			space_len = regularize();
			if (space_len < want_len) {
				size_t nsize = m_buffer_size * 2;
				size_t dlen = data_len();
				while ((nsize - dlen) < want_len){
					nsize *= 2;
				}
				space_len = resize(nsize);
			}
		}
		*len = space_len;
		return m_data_end;
	}

	void pop_space(size_t pop_len)
	{
		assert(m_data_end + pop_len <= m_buffer_end);
		m_data_end += pop_len;
	}

	BYTE* peek_data(size_t* data_len)
	{
		*data_len = (size_t)(m_data_end - m_data_begin);
		return m_data_begin;
	}

	bool empty() { return m_data_end <= m_data_begin; }

	BYTE* data()
	{
		return m_data_begin;
	}

	size_t data_len()
	{
		return (size_t)(m_data_end - m_data_begin);
	}
	
	size_t capacity() {
		return m_buffer_size;
	}

	inline bool read(uint32_t bytes, void* out_buffer) {
		if (data_len() < bytes) return false;
		memcpy(out_buffer, m_data_begin, bytes);
		pop_data(bytes);
		return true;
	}

	template<typename T>
	inline bool Read(T& t) { return read(sizeof(T), &t); }

	template<typename T>
	inline bool Write(const T& t) { return push_data(&t, sizeof(T)); }
protected:
	size_t regularize()
	{
		size_t data_len = (size_t)(m_data_end - m_data_begin);
		if (m_data_begin > m_buffer)
		{
			if (data_len > 0)
			{
				memmove(m_buffer, m_data_begin, data_len);
			}
			m_data_end = m_buffer + data_len;
			m_data_begin = m_buffer;
		}
		return m_buffer_size - data_len;
	}

	void alloc_buffer(size_t align_size)
	{
		m_align_size = align_size;
		m_align_max = m_align_size * IO_ALIGN_SIZE;
		m_buffer = (BYTE*)malloc(align_size);
		m_buffer_size = align_size;
		m_data_begin = m_buffer;
		m_data_end = m_data_begin;
		m_buffer_end = m_buffer + m_buffer_size;
	}

private:
	BYTE* m_data_begin = nullptr;
	BYTE* m_data_end = nullptr;
	BYTE* m_buffer = nullptr;
	BYTE* m_buffer_end = nullptr;
	size_t m_buffer_size = 0;
	size_t m_align_size = 0;
	size_t m_align_max = 0;
};
