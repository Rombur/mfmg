/*************************************************************************
 * Copyright (c) 2018 by the mfmg authors                                *
 * All rights reserved.                                                  *
 *                                                                       *
 * This file is part of the mfmg libary. mfmg is distributed under a BSD *
 * 3-clause license. For the licensing terms see the LICENSE file in the *
 * top-level directory                                                   *
 *                                                                       *
 * SPDX-License-Identifier: BSD-3-Clause                                 *
 *************************************************************************/

#define BOOST_TEST_MODULE amgx_direct_solver

#include "main.cc"

#if MFMG_WITH_AMGX
#include <mfmg/dealii_operator_device.cuh>
#include <mfmg/sparse_matrix_device.cuh>
#include <mfmg/vector_device.cuh>

#include <boost/property_tree/ptree.hpp>
#include <cusolverDn.h>
#include <cusolverSp.h>

BOOST_AUTO_TEST_CASE(amgx_1_proc)
{
  int comm_size = dealii::Utilities::MPI::n_mpi_processes(MPI_COMM_WORLD);
  if (comm_size == 1)
  {
    // Create the cusolver_dn_handle
    cusolverDnHandle_t cusolver_dn_handle = nullptr;
    cusolverStatus_t cusolver_error_code;
    cusolver_error_code = cusolverDnCreate(&cusolver_dn_handle);
    mfmg::ASSERT_CUSOLVER(cusolver_error_code);
    // Create the cusolver_sp_handle
    cusolverSpHandle_t cusolver_sp_handle = nullptr;
    cusolver_error_code = cusolverSpCreate(&cusolver_sp_handle);
    mfmg::ASSERT_CUSOLVER(cusolver_error_code);
    // Create the cusparse_handle
    cusparseHandle_t cusparse_handle = nullptr;
    cusparseStatus_t cusparse_error_code;
    cusparse_error_code = cusparseCreate(&cusparse_handle);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);

    // Create the matrix on the host.
    dealii::SparsityPattern sparsity_pattern;
    dealii::SparseMatrix<double> matrix;
    unsigned int const size = 3000;
    std::vector<std::vector<unsigned int>> column_indices(size);
    for (unsigned int i = 0; i < size; ++i)
    {
      unsigned int j_max = std::min(size, i + 2);
      unsigned int j_min = (i == 0) ? 0 : i - 1;
      for (unsigned int j = j_min; j < j_max; ++j)
        column_indices[i].emplace_back(j);
    }
    sparsity_pattern.copy_from(size, size, column_indices.begin(),
                               column_indices.end());
    matrix.reinit(sparsity_pattern);
    for (unsigned int i = 0; i < size; ++i)
    {
      unsigned int j_max = std::min(size - 1, i + 1);
      unsigned int j_min = (i == 0) ? 0 : i - 1;
      matrix.set(i, j_min, -1.);
      matrix.set(i, j_max, -1.);
      matrix.set(i, i, 4.);
    }

    // Generate a random solution and then compute the rhs
    dealii::Vector<double> sol_ref(size);
    std::default_random_engine generator;
    std::normal_distribution<> distribution(10., 2.);
    for (auto &val : sol_ref)
      val = distribution(generator);

    dealii::Vector<double> rhs(size);
    matrix.vmult(rhs, sol_ref);

    // Move the matrix and the rhs to the device
    mfmg::SparseMatrixDevice<double> matrix_dev(mfmg::convert_matrix(matrix));
    matrix_dev.cusparse_handle = cusparse_handle;
    cusparse_error_code = cusparseCreateMatDescr(&matrix_dev.descr);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);
    cusparse_error_code =
        cusparseSetMatType(matrix_dev.descr, CUSPARSE_MATRIX_TYPE_GENERAL);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);
    cusparse_error_code =
        cusparseSetMatIndexBase(matrix_dev.descr, CUSPARSE_INDEX_BASE_ZERO);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);
    auto partitioner =
        std::make_shared<dealii::Utilities::MPI::Partitioner>(size);
    mfmg::VectorDevice<double> rhs_dev(partitioner);
    mfmg::VectorDevice<double> solution_dev(partitioner);
    std::vector<double> rhs_host(size);
    std::copy(rhs.begin(), rhs.end(), rhs_host.begin());
    mfmg::cuda_mem_copy_to_dev(rhs_host, rhs_dev.val_dev);
    auto params = std::make_shared<boost::property_tree::ptree>();

    params->put("solver.type", "amgx");
    params->put("solver.config_file", "amgx_config_fgmres.json");
    mfmg::DirectDeviceOperator<mfmg::VectorDevice<double>> direct_solver_dev(
        cusolver_dn_handle, cusolver_sp_handle, matrix_dev, params);
    BOOST_CHECK_EQUAL(direct_solver_dev.m(), matrix_dev.m());
    BOOST_CHECK_EQUAL(direct_solver_dev.n(), matrix_dev.n());
    direct_solver_dev.apply(rhs_dev, solution_dev);

    // Move the result back to the host
    int const n_local_rows = matrix_dev.n_local_rows();
    std::vector<double> solution_host(n_local_rows);
    mfmg::cuda_mem_copy_to_host(solution_dev.val_dev, solution_host);

    // Check the result
    for (unsigned int i = 0; i < n_local_rows; ++i)
      BOOST_CHECK_CLOSE(solution_host[i], sol_ref[i], 1e-7);

    // Clean up the memory
    cusolver_error_code = cusolverDnDestroy(cusolver_dn_handle);
    mfmg::ASSERT_CUSOLVER(cusolver_error_code);
    cusolver_error_code = cusolverSpDestroy(cusolver_sp_handle);
    mfmg::ASSERT_CUSOLVER(cusolver_error_code);
    cusparse_error_code = cusparseDestroy(cusparse_handle);
    mfmg::ASSERT_CUSPARSE(cusparse_error_code);
  }
}

BOOST_AUTO_TEST_CASE(amgx_2_procs)
{
  int n_devices = 0;
  cudaError_t cuda_error_code = cudaGetDeviceCount(&n_devices);
  mfmg::ASSERT_CUDA(cuda_error_code);
  int comm_size = dealii::Utilities::MPI::n_mpi_processes(MPI_COMM_WORLD);
  if ((n_devices == 2) && (comm_size == 2))
  {
    int rank = dealii::Utilities::MPI::this_mpi_process(MPI_COMM_WORLD);
    if (rank < 2)
    {
      cuda_error_code = cudaSetDevice(rank);

      // Create the cusolver_dn_handle
      cusolverDnHandle_t cusolver_dn_handle = nullptr;
      cusolverStatus_t cusolver_error_code;
      cusolver_error_code = cusolverDnCreate(&cusolver_dn_handle);
      mfmg::ASSERT_CUSOLVER(cusolver_error_code);
      // Create the cusolver_sp_handle
      cusolverSpHandle_t cusolver_sp_handle = nullptr;
      cusolver_error_code = cusolverSpCreate(&cusolver_sp_handle);
      mfmg::ASSERT_CUSOLVER(cusolver_error_code);
      // Create the cusparse_handle
      cusparseHandle_t cusparse_handle = nullptr;
      cusparseStatus_t cusparse_error_code;
      cusparse_error_code = cusparseCreate(&cusparse_handle);
      mfmg::ASSERT_CUSPARSE(cusparse_error_code);

      // Create the matrix on the host.
      unsigned int const n_local_rows = 10000;
      unsigned int const row_offset = rank * n_local_rows;
      unsigned int const size = comm_size * n_local_rows;
      dealii::IndexSet parallel_partitioning(size);
      for (unsigned int i = 0; i < n_local_rows; ++i)
        parallel_partitioning.add_index(row_offset + i);
      parallel_partitioning.compress();
      dealii::TrilinosWrappers::SparseMatrix sparse_matrix(
          parallel_partitioning);

      for (unsigned int i = 0; i < n_local_rows; ++i)
      {
        unsigned int const row = row_offset + i;
        unsigned int j_max = std::min(size - 1, row + 1);
        unsigned int j_min = (row == 0) ? 0 : row - 1;
        sparse_matrix.set(row, j_min, -1.);
        sparse_matrix.set(row, j_max, -1.);
        sparse_matrix.set(row, row, 4.);
      }

      sparse_matrix.compress(dealii::VectorOperation::insert);

      // Generate a random solution and then compute the rhs
      auto range_indexset = sparse_matrix.locally_owned_range_indices();
      dealii::LinearAlgebra::distributed::Vector<double> sol_ref(
          range_indexset, MPI_COMM_WORLD);
      for (unsigned int i = 0; i < n_local_rows; ++i)
        sol_ref.local_element(i) = row_offset + i + 1;

      dealii::LinearAlgebra::distributed::Vector<double> rhs(range_indexset,
                                                             MPI_COMM_WORLD);
      sparse_matrix.vmult(rhs, sol_ref);

      // Move the matrix and the rhs to the device
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
      mfmg::VectorDevice<double> rhs_dev(rhs);
      mfmg::VectorDevice<double> solution_dev(sol_ref);
      auto params = std::make_shared<boost::property_tree::ptree>();

      params->put("solver.type", "amgx");
      params->put("solver.config_file", "amgx_config_fgmres.json");
      mfmg::DirectDeviceOperator<mfmg::VectorDevice<double>> direct_solver_dev(
          cusolver_dn_handle, cusolver_sp_handle, matrix_dev, params);
      BOOST_CHECK_EQUAL(direct_solver_dev.m(), matrix_dev.m());
      BOOST_CHECK_EQUAL(direct_solver_dev.n(), matrix_dev.n());

      // Move the result back to the host
      std::vector<double> solution_host(n_local_rows);
      mfmg::cuda_mem_copy_to_host(solution_dev.val_dev, solution_host);

      for (unsigned int i = 0; i < n_local_rows; ++i)
        BOOST_CHECK_CLOSE(solution_host[i], sol_ref.local_element(i), 1e-7);

      // Clean up the memory
      cusolver_error_code = cusolverDnDestroy(cusolver_dn_handle);
      mfmg::ASSERT_CUSOLVER(cusolver_error_code);
      cusolver_error_code = cusolverSpDestroy(cusolver_sp_handle);
      mfmg::ASSERT_CUSOLVER(cusolver_error_code);
      cusparse_error_code = cusparseDestroy(cusparse_handle);
      mfmg::ASSERT_CUSPARSE(cusparse_error_code);
    }
  }
}
#endif
