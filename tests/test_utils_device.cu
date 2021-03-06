/**************************************************************************
 * Copyright (c) 2017-2019 by the mfmg authors                            *
 * All rights reserved.                                                   *
 *                                                                        *
 * This file is part of the mfmg library. mfmg is distributed under a BSD *
 * 3-clause license. For the licensing terms see the LICENSE file in the  *
 * top-level directory                                                    *
 *                                                                        *
 * SPDX-License-Identifier: BSD-3-Clause                                  *
 *************************************************************************/

#define BOOST_TEST_MODULE utils_device

#include <mfmg/cuda/sparse_matrix_device.cuh>
#include <mfmg/cuda/utils.cuh>

#include <deal.II/base/index_set.h>
#include <deal.II/lac/sparse_matrix.h>
#include <deal.II/lac/sparsity_pattern.h>
#include <deal.II/lac/trilinos_sparse_matrix.h>

#include <algorithm>
#include <random>
#include <set>

#include "main.cc"

template <typename ScalarType>
std::vector<ScalarType> copy_to_host(ScalarType *val_dev,
                                     unsigned int n_elements)
{
  mfmg::ASSERT(n_elements > 0, "Cannot copy an empty array to the host");
  std::vector<ScalarType> val_host(n_elements);
  cudaError_t error_code =
      cudaMemcpy(&val_host[0], val_dev, n_elements * sizeof(ScalarType),
                 cudaMemcpyDeviceToHost);
  mfmg::ASSERT_CUDA(error_code);

  return val_host;
}

template <typename ScalarType>
std::tuple<std::vector<ScalarType>, std::vector<int>, std::vector<int>>
copy_sparse_matrix_to_host(
    mfmg::SparseMatrixDevice<ScalarType> const &sparse_matrix_dev)
{
  std::vector<ScalarType> val =
      copy_to_host(sparse_matrix_dev.val_dev, sparse_matrix_dev.local_nnz());

  std::vector<int> column_index = copy_to_host(
      sparse_matrix_dev.column_index_dev, sparse_matrix_dev.local_nnz());

  std::vector<int> row_ptr =
      copy_to_host(sparse_matrix_dev.row_ptr_dev, sparse_matrix_dev.m() + 1);

  return std::make_tuple(val, column_index, row_ptr);
}

BOOST_AUTO_TEST_CASE(dealii_sparse_matrix_square)
{
  // Build the sparsity pattern
  dealii::SparsityPattern sparsity_pattern;
  unsigned int const size = 30;
  std::vector<std::vector<unsigned int>> column_indices(size);
  for (unsigned int i = 0; i < size; ++i)
  {
    std::vector<unsigned int> indices;
    std::default_random_engine generator(i);
    std::uniform_int_distribution<int> distribution(0, size - 1);
    for (unsigned int j = 0; j < 5; ++j)
      indices.push_back(distribution(generator));
    indices.push_back(i);

    std::sort(indices.begin(), indices.end());
    indices.erase(std::unique(indices.begin(), indices.end()), indices.end());

    column_indices[i] = indices;
  }
  sparsity_pattern.copy_from(size, size, column_indices.begin(),
                             column_indices.end());

  // Build the sparse matrix
  dealii::SparseMatrix<double> sparse_matrix(sparsity_pattern);
  for (unsigned int i = 0; i < size; ++i)
    for (unsigned int j = 0; j < size; ++j)
      if (sparsity_pattern.exists(i, j))
        sparse_matrix.set(i, j, static_cast<double>(i + j));

  // Move the sparse matrix to the device and change the format to a regular CSR
  mfmg::SparseMatrixDevice<double> sparse_matrix_dev =
      mfmg::convert_matrix(sparse_matrix);

  // Copy the matrix from the gpu
  std::vector<double> val_host;
  std::vector<int> column_index_host;
  std::vector<int> row_ptr_host;
  std::tie(val_host, column_index_host, row_ptr_host) =
      copy_sparse_matrix_to_host(sparse_matrix_dev);

  // Check the result
  unsigned int const n_rows = sparse_matrix_dev.m();
  unsigned int pos = 0;
  for (unsigned int i = 0; i < n_rows; ++i)
    for (unsigned int j = row_ptr_host[i]; j < row_ptr_host[i + 1]; ++j, ++pos)
      BOOST_CHECK_EQUAL(val_host[pos], sparse_matrix(i, column_index_host[j]));
}

BOOST_AUTO_TEST_CASE(dealii_sparse_matrix_rectangle)
{
  // Build the sparsity pattern
  dealii::SparsityPattern sparsity_pattern;
  unsigned int const n_rows = 30;
  unsigned int const nnz_per_row = 10;
  unsigned int const n_cols = n_rows + nnz_per_row - 1;
  std::vector<std::vector<unsigned int>> column_indices(
      n_rows, std::vector<unsigned int>(nnz_per_row));
  for (unsigned int i = 0; i < n_rows; ++i)
    for (unsigned int j = 0; j < nnz_per_row; ++j)
      column_indices[i][j] = i + j;
  sparsity_pattern.copy_from(n_rows, n_cols, column_indices.begin(),
                             column_indices.end());

  // Build the sparse matrix
  dealii::SparseMatrix<double> sparse_matrix(sparsity_pattern);
  for (unsigned int i = 0; i < n_rows; ++i)
    for (unsigned int j = 0; j < nnz_per_row; ++j)
      sparse_matrix.set(i, i + j, static_cast<double>(i + j));

  // Move the sparse matrix to the device and change the format to a regular CSR
  mfmg::SparseMatrixDevice<double> sparse_matrix_dev =
      mfmg::convert_matrix(sparse_matrix);

  BOOST_CHECK_EQUAL(sparse_matrix_dev.m(), n_rows);
  BOOST_CHECK_EQUAL(sparse_matrix_dev.n(), n_cols);

  // Copy the matrix from the gpu
  std::vector<double> val_host;
  std::vector<int> column_index_host;
  std::vector<int> row_ptr_host;
  std::tie(val_host, column_index_host, row_ptr_host) =
      copy_sparse_matrix_to_host(sparse_matrix_dev);

  // Check the result
  unsigned int pos = 0;
  for (unsigned int i = 0; i < n_rows; ++i)
    for (unsigned int j = row_ptr_host[i]; j < row_ptr_host[i + 1]; ++j, ++pos)
      BOOST_CHECK_EQUAL(val_host[pos], sparse_matrix(i, column_index_host[j]));
}

// Check that we can convert a TrilinosWrappers::SparseMatrix and an
// Epetra_CrsMatrix. We cannot use BOOST_DATA_TEST_CASE here because nvcc does
// not support variadic macros
BOOST_AUTO_TEST_CASE(trilinos_sparse_matrix)
{
  // We need serialize the access to the GPU so that we don't have any problem
  // when multiple MPI ranks want to access the GPU. In practice, we would need
  // to use MPS but we don't have any control on this (it is the user
  // responsibility to set up her GPU correctly). We cannot use MPI_Barrier to
  // serialize the access because the constructor of SparseMatrixDevice calls
  // MPI_AllReduce. So we run the test in serial

  // Build the sparse matrix
  unsigned int const comm_size =
      dealii::Utilities::MPI::n_mpi_processes(MPI_COMM_WORLD);
  if (comm_size == 1)
  {
    unsigned int const n_local_rows = 10;
    unsigned int const size = comm_size * n_local_rows;
    dealii::IndexSet parallel_partitioning(size);
    for (unsigned int i = 0; i < n_local_rows; ++i)
      parallel_partitioning.add_index(i);
    parallel_partitioning.compress();
    dealii::TrilinosWrappers::SparseMatrix sparse_matrix(parallel_partitioning);

    unsigned int nnz = 0;
    for (unsigned int i = 0; i < n_local_rows; ++i)
    {
      std::default_random_engine generator(i);
      std::uniform_int_distribution<int> distribution(0, size - 1);
      std::set<int> column_indices;
      for (unsigned int j = 0; j < 5; ++j)
      {
        int column_index = distribution(generator);
        sparse_matrix.set(i, column_index, static_cast<double>(i + j));
        column_indices.insert(column_index);
      }
      nnz += column_indices.size();
    }
    sparse_matrix.compress(dealii::VectorOperation::insert);

    // Move the sparse matrix to the device.
    for (auto matrix_type : {"trilinos_wrapper", "epetra"})
    {
      // Move the sparse matrix to the device and change the format to a
      // regular CSR
      std::shared_ptr<mfmg::SparseMatrixDevice<double>> sparse_matrix_dev;
      if (matrix_type == "trilinos_wrapper")
        sparse_matrix_dev = std::make_shared<mfmg::SparseMatrixDevice<double>>(
            mfmg::convert_matrix(sparse_matrix));
      else
        sparse_matrix_dev = std::make_shared<mfmg::SparseMatrixDevice<double>>(
            mfmg::convert_matrix(sparse_matrix.trilinos_matrix()));

      // Copy the matrix from the gpu
      std::vector<double> val_host;
      std::vector<int> column_index_host;
      std::vector<int> row_ptr_host;
      std::tie(val_host, column_index_host, row_ptr_host) =
          copy_sparse_matrix_to_host(*sparse_matrix_dev);

      unsigned int pos = 0;
      for (unsigned int i = 0; i < n_local_rows; ++i)
        for (unsigned int j = row_ptr_host[i]; j < row_ptr_host[i + 1];
             ++j, ++pos)
          BOOST_CHECK_EQUAL(val_host[pos],
                            sparse_matrix(i, column_index_host[j]));
    }
  }
}

BOOST_AUTO_TEST_CASE(sparse_matrix_device)
{
  // Build the sparse matrix
  unsigned int const comm_size =
      dealii::Utilities::MPI::n_mpi_processes(MPI_COMM_WORLD);
  if (comm_size == 1)
  {
    unsigned int const n_local_rows = 10;
    unsigned int const size = comm_size * n_local_rows;
    dealii::IndexSet parallel_partitioning(size);
    for (unsigned int i = 0; i < n_local_rows; ++i)
      parallel_partitioning.add_index(i);
    parallel_partitioning.compress();
    dealii::TrilinosWrappers::SparseMatrix sparse_matrix(parallel_partitioning);

    unsigned int nnz = 0;
    for (unsigned int i = 0; i < n_local_rows; ++i)
    {
      std::default_random_engine generator(i);
      std::uniform_int_distribution<int> distribution(0, size - 1);
      std::set<int> column_indices;
      for (unsigned int j = 0; j < 5; ++j)
      {
        int column_index = distribution(generator);
        sparse_matrix.set(i, column_index, static_cast<double>(i + j));
        column_indices.insert(column_index);
      }
      nnz += column_indices.size();
    }
    sparse_matrix.compress(dealii::VectorOperation::insert);

    // Move the sparse matrix to the device.
    auto sparse_matrix_dev = mfmg::convert_matrix(sparse_matrix);

    // Move the sparse matrix back to the host
    auto sparse_matrix_host =
        mfmg::convert_to_trilinos_matrix(sparse_matrix_dev);

    for (unsigned int i = 0; i < size; ++i)
      for (unsigned int j = 0; j < size; ++j)
        BOOST_CHECK_EQUAL(sparse_matrix_host.el(i, j), sparse_matrix.el(i, j));
  }
}

BOOST_AUTO_TEST_CASE(amgx_format)
{
  int comm_size = dealii::Utilities::MPI::n_mpi_processes(MPI_COMM_WORLD);
  if (comm_size == 1)
  {
    // Create the cusparse_handle
    cusparseHandle_t cusparse_handle = nullptr;
    cusparseStatus_t cusparse_error_code;
    cusparse_error_code = cusparseCreate(&cusparse_handle);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);

    // Create the matrix on the host.
    unsigned int const n_rows = 10;
    auto parallel_partitioning = dealii::complete_index_set(n_rows);
    parallel_partitioning.compress();
    dealii::TrilinosWrappers::SparseMatrix sparse_matrix(parallel_partitioning);

    for (unsigned int i = 0; i < n_rows; ++i)
    {
      unsigned int j_max = std::min(n_rows - 1, i + 1);
      unsigned int j_min = (i == 0) ? 0 : i - 1;
      sparse_matrix.set(i, j_min, -1.);
      sparse_matrix.set(i, j_max, -1.);
      sparse_matrix.set(i, i, 4.);
    }
    sparse_matrix.compress(dealii::VectorOperation::insert);

    // Move the matrix
    mfmg::SparseMatrixDevice<double> matrix_dev(
        mfmg::convert_matrix(sparse_matrix));
    matrix_dev.cusparse_handle = cusparse_handle;
    cusparse_error_code = cusparseCreateMatDescr(&matrix_dev.descr);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);
    cusparse_error_code =
        cusparseSetMatType(matrix_dev.descr, CUSPARSE_MATRIX_TYPE_GENERAL);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);
    cusparse_error_code =
        cusparseSetMatIndexBase(matrix_dev.descr, CUSPARSE_INDEX_BASE_ZERO);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);

    // The first, the third, and the fifth rows will be send to another
    // processors
    std::unordered_set<int> rows_sent;
    rows_sent.insert(0);
    rows_sent.insert(2);
    rows_sent.insert(4);

    mfmg::csr_to_amgx(rows_sent, matrix_dev);

    // Move the data to the host and compare the result
    std::vector<double> value_ref = {
        4.,  -1., -1., 4.,  -1., -1., 4.,  -1., -1., -1., 4., -1., -1., 4.,
        -1., -1., 4.,  -1., -1., 3.,  -1., 3.,  -1., -1., 4., -1., -1., 4.};
    std::vector<int> col_index_ref = {0, 7, 8, 1, 8, 9, 2, 3, 9, 2, 3, 4, 3, 4,
                                      5, 4, 5, 6, 5, 6, 0, 7, 0, 1, 8, 1, 2, 9};
    std::vector<int> row_ptr_ref = {0, 3, 6, 9, 12, 15, 18, 20, 22, 25, 28};

    unsigned int const local_nnz = matrix_dev.local_nnz();
    unsigned int const n_local_rows = matrix_dev.n_local_rows();
    std::vector<double> value_host(local_nnz);
    mfmg::cuda_mem_copy_to_host(matrix_dev.val_dev, value_host);
    std::vector<int> col_index_host(local_nnz);
    mfmg::cuda_mem_copy_to_host(matrix_dev.column_index_dev, col_index_host);
    std::vector<int> row_ptr_host(n_local_rows + 1);
    mfmg::cuda_mem_copy_to_host(matrix_dev.row_ptr_dev, row_ptr_host);

    for (unsigned int i = 0; i < local_nnz; ++i)
      BOOST_CHECK_EQUAL(value_host[i], value_ref[i]);

    for (unsigned int i = 0; i < local_nnz; ++i)
      BOOST_CHECK_EQUAL(col_index_host[i], col_index_ref[i]);

    for (unsigned int i = 0; i < n_local_rows + 1; ++i)
      BOOST_CHECK_EQUAL(row_ptr_host[i], row_ptr_ref[i]);
  }
}

BOOST_AUTO_TEST_CASE(cuda_mpi)
{
  MPI_Comm comm = MPI_COMM_WORLD;
  unsigned int const comm_size = dealii::Utilities::MPI::n_mpi_processes(comm);
  unsigned int const rank = dealii::Utilities::MPI::this_mpi_process(comm);
  int n_devices = 0;
  cudaError_t cuda_error_code = cudaGetDeviceCount(&n_devices);
  mfmg::ASSERT_CUDA(cuda_error_code);

  // Set the device for each process
  int device_id = rank % n_devices;
  cuda_error_code = cudaSetDevice(device_id);

  unsigned int const local_size = 10 + rank;
  std::vector<double> send_buffer_host(local_size, rank);
  double *send_buffer_dev;
  mfmg::cuda_malloc(send_buffer_dev, local_size);
  cuda_error_code =
      cudaMemcpy(send_buffer_dev, send_buffer_host.data(),
                 local_size * sizeof(double), cudaMemcpyHostToDevice);
  mfmg::ASSERT_CUDA(cuda_error_code);

  unsigned int size = 0;
  for (unsigned int i = 0; i < comm_size; ++i)
    size += 10 + i;
  double *recv_buffer_dev;
  mfmg::cuda_malloc(recv_buffer_dev, size);

  mfmg::all_gather_dev(comm, local_size, send_buffer_dev, size,
                       recv_buffer_dev);

  std::vector<double> recv_buffer_host(size);
  cuda_error_code = cudaMemcpy(recv_buffer_host.data(), recv_buffer_dev,
                               size * sizeof(double), cudaMemcpyDeviceToHost);
  mfmg::ASSERT_CUDA(cuda_error_code);

  std::vector<double> recv_buffer_ref;
  recv_buffer_ref.reserve(size);
  for (unsigned int i = 0; i < comm_size; ++i)
    for (unsigned int j = 0; j < 10 + i; ++j)
      recv_buffer_ref.push_back(i);

  for (unsigned int i = 0; i < size; ++i)
    BOOST_CHECK_EQUAL(recv_buffer_host[i], recv_buffer_ref[i]);

  mfmg::cuda_free(send_buffer_dev);
  mfmg::cuda_free(recv_buffer_dev);
}
