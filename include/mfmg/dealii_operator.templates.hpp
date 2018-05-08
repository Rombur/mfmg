/*************************************************************************
 * Copyright (c) 2017-2018 by the mfmg authors                           *
 * All rights reserved.                                                  *
 *                                                                       *
 * This file is part of the mfmg libary. mfmg is distributed under a BSD *
 * 3-clause license. For the licensing terms see the LICENSE file in the *
 * top-level directory                                                   *
 *                                                                       *
 * SPDX-License-Identifier: BSD-3-Clause                                 *
 *************************************************************************/

#ifndef MFMG_DEALII_OPERATOR_TEMPLATES_HPP
#define MFMG_DEALII_OPERATOR_TEMPLATES_HPP

#include <mfmg/dealii_operator.hpp>
#include <mfmg/utils.hpp>

#include <EpetraExt_Transpose_RowMatrix.h>
#include <ml_MultiLevelPreconditioner.h>
#include <ml_Preconditioner.h>

namespace mfmg
{
template <typename VectorType>
DealIIMatrixOperator<VectorType>::DealIIMatrixOperator(
    std::shared_ptr<typename DealIIMatrixOperator<VectorType>::matrix_type>
        matrix,
    std::shared_ptr<dealii::SparsityPattern> sparsity_pattern)
    : _sparsity_pattern(sparsity_pattern), _matrix(matrix)
{
  ASSERT(sparsity_pattern != nullptr,
         "deal.II matrices require a sparsity pattern");

  ASSERT(matrix != nullptr, "The matrix must exist");
}

template <typename VectorType>
void DealIIMatrixOperator<VectorType>::apply(VectorType const &x,
                                             VectorType &y) const
{
  _matrix->vmult(y, x);
}

template <typename VectorType>
std::shared_ptr<MatrixOperator<VectorType>>
DealIIMatrixOperator<VectorType>::transpose() const
{
  ASSERT_THROW_NOT_IMPLEMENTED();

  return nullptr;
}

template <typename VectorType>
std::shared_ptr<MatrixOperator<VectorType>>
DealIIMatrixOperator<VectorType>::multiply(
    MatrixOperator<VectorType> const &) const
{
  ASSERT_THROW_NOT_IMPLEMENTED();

  return nullptr;
}

template <typename VectorType>
std::shared_ptr<VectorType>
DealIIMatrixOperator<VectorType>::build_domain_vector() const
{
  ASSERT_THROW_NOT_IMPLEMENTED();

  return nullptr;
}

template <typename VectorType>
std::shared_ptr<VectorType>
DealIIMatrixOperator<VectorType>::build_range_vector() const
{
  ASSERT_THROW_NOT_IMPLEMENTED();

  return nullptr;
}

//-------------------------------------------------------------------------//

template <typename VectorType>
DealIITrilinosMatrixOperator<VectorType>::DealIITrilinosMatrixOperator(
    std::shared_ptr<dealii::TrilinosWrappers::SparseMatrix> matrix,
    std::shared_ptr<dealii::TrilinosWrappers::SparsityPattern>)
    : _matrix(matrix)
{
}

template <typename VectorType>
void DealIITrilinosMatrixOperator<VectorType>::apply(VectorType const &x,
                                                     vector_type &y) const
{
  _matrix->vmult(y, x);
}

template <typename VectorType>
std::shared_ptr<MatrixOperator<VectorType>>
DealIITrilinosMatrixOperator<VectorType>::transpose() const
{
  auto epetra_matrix = _matrix->trilinos_matrix();

  EpetraExt::RowMatrix_Transpose transposer;
  auto transposed_epetra_matrix =
      dynamic_cast<Epetra_CrsMatrix &>(transposer(epetra_matrix));

  auto transposed_matrix = std::make_shared<matrix_type>();
  transposed_matrix->reinit(transposed_epetra_matrix);

  return std::make_shared<DealIITrilinosMatrixOperator<VectorType>>(
      transposed_matrix);
}

template <typename VectorType>
std::shared_ptr<MatrixOperator<VectorType>>
DealIITrilinosMatrixOperator<VectorType>::multiply(
    MatrixOperator<VectorType> const &operator_b) const
{
  // Downcast to TrilinosMatrixOperator
  auto downcast_operator_b =
      static_cast<DealIITrilinosMatrixOperator<VectorType> const &>(operator_b);

  auto a = this->get_matrix();
  auto b = downcast_operator_b.get_matrix();

  auto c = std::make_shared<matrix_type>();
  a->mmult(*c, *b);

  return std::make_shared<DealIITrilinosMatrixOperator<VectorType>>(c);
}

template <typename VectorType>
std::shared_ptr<VectorType>
DealIITrilinosMatrixOperator<VectorType>::build_domain_vector() const
{
  return std::make_shared<vector_type>(_matrix->locally_owned_domain_indices(),
                                       _matrix->get_mpi_communicator());
}

template <typename VectorType>
std::shared_ptr<VectorType>
DealIITrilinosMatrixOperator<VectorType>::build_range_vector() const
{
  return std::make_shared<vector_type>(_matrix->locally_owned_range_indices(),
                                       _matrix->get_mpi_communicator());
}

//-------------------------------------------------------------------------//

template <typename VectorType>
DealIISmootherOperator<VectorType>::DealIISmootherOperator(
    matrix_type const &matrix,
    std::shared_ptr<boost::property_tree::ptree> params)
    : _matrix(matrix)
{
  std::string prec_type =
      params->get("smoother.type", "Symmetric Gauss-Seidel");
  initialize(prec_type);
}

template <typename VectorType>
void DealIISmootherOperator<VectorType>::apply(VectorType const &b,
                                               VectorType &x) const
{
  // r = -(b - Ax)
  vector_type r(b);
  _matrix.vmult(r, x);
  r.add(-1., b);

  // x = x + B^{-1} (-r)
  vector_type tmp(x);
  _smoother->vmult(tmp, r);
  x.add(-1., tmp);
}

template <typename VectorType>
std::shared_ptr<VectorType>
DealIISmootherOperator<VectorType>::build_domain_vector() const
{
  ASSERT_THROW_NOT_IMPLEMENTED();

  return nullptr;
}

template <typename VectorType>
std::shared_ptr<VectorType>
DealIISmootherOperator<VectorType>::build_range_vector() const
{
  ASSERT_THROW_NOT_IMPLEMENTED();

  return nullptr;
}

template <typename VectorType>
void DealIISmootherOperator<VectorType>::initialize(
    std::string const &prec_name)
{
  // Make parameters case-insensitive
  std::string prec_name_lower = prec_name;
  std::transform(prec_name_lower.begin(), prec_name_lower.end(),
                 prec_name_lower.begin(), ::tolower);
  if (prec_name_lower == "symmetric gauss-seidel")
  {
    _smoother.reset(new dealii::TrilinosWrappers::PreconditionSSOR());
    static_cast<dealii::TrilinosWrappers::PreconditionSSOR *>(_smoother.get())
        ->initialize(_matrix);
  }
  else if (prec_name_lower == "gauss-seidel")
  {
    _smoother.reset(new dealii::TrilinosWrappers::PreconditionSOR());
    static_cast<dealii::TrilinosWrappers::PreconditionSOR *>(_smoother.get())
        ->initialize(_matrix);
  }
  else if (prec_name_lower == "jacobi")
  {
    _smoother.reset(new dealii::TrilinosWrappers::PreconditionJacobi());
    static_cast<dealii::TrilinosWrappers::PreconditionJacobi *>(_smoother.get())
        ->initialize(_matrix);
  }
  else if (prec_name_lower == "ilu")
  {
    _smoother.reset(new dealii::TrilinosWrappers::PreconditionILU());
    static_cast<dealii::TrilinosWrappers::PreconditionILU *>(_smoother.get())
        ->initialize(_matrix);
  }
  else
    ASSERT_THROW(false, "Unknown smoother name: \"" + prec_name_lower + "\"");
}

//-------------------------------------------------------------------------//

template <typename VectorType>
DealIIDirectOperator<VectorType>::DealIIDirectOperator(
    matrix_type const &matrix,
    std::shared_ptr<boost::property_tree::ptree> params)
{
  _m = matrix.m();
  _n = matrix.n();
  _nnz = matrix.n_nonzero_elements();

  std::string coarse_type;
  if (params != nullptr)
    coarse_type = params->get("coarse.type", "");

  // Make parameters case-insensitive
  std::string coarse_type_lower = coarse_type;
  std::transform(coarse_type_lower.begin(), coarse_type_lower.end(),
                 coarse_type_lower.begin(), ::tolower);

  if (coarse_type_lower == "" || coarse_type_lower == "direct")
  {
    _solver.reset(new solver_type(_solver_control));
    _solver->initialize(matrix);
  }
  else
  {
    if (coarse_type_lower == "ml")
    {
      auto ml_tree = params->get_child_optional("coarse.params");

      // For now, always set defaults to SA
      Teuchos::ParameterList ml_params;
      ML_Epetra::SetDefaults("SA", ml_params);

      if (ml_tree)
      {
        // Augment with user provided parameters
        ptree2plist(*ml_tree, ml_params);
      }

      _smoother.reset(new dealii::TrilinosWrappers::PreconditionAMG());
      static_cast<dealii::TrilinosWrappers::PreconditionAMG *>(_smoother.get())
          ->initialize(matrix, ml_params);
    }
    else
      ASSERT_THROW(false,
                   "Unknown coarse solver name: \"" + coarse_type_lower + "\"");
  }
}

template <typename VectorType>
size_t DealIIDirectOperator<VectorType>::grid_complexity() const
{
  check_state();
  if (_solver)
    return m();
  else
  {
    auto const &epetra_operator = _smoother->trilinos_operator();
    auto const &ml_operator =
        dynamic_cast<ML_Epetra::MultiLevelPreconditioner const &>(
            epetra_operator);
    auto ml = ml_operator.GetML();

    size_t complexity = 0;
    for (int i = 0; i < ml->ML_num_actual_levels; i++)
    {
      long long local = ml->Amat[ml->LevelID[i]].invec_leng, global;
      ml_operator.Comm().SumAll(&local, &global, 1);
      complexity += global;
    }

    return complexity;
  }
}

template <typename VectorType>
size_t DealIIDirectOperator<VectorType>::operator_complexity() const
{
  check_state();
  if (_solver)
    return _nnz;
  else
  {
    auto &epetra_operator = _smoother->trilinos_operator();
    auto &ml_operator =
        dynamic_cast<ML_Epetra::MultiLevelPreconditioner &>(epetra_operator);
    double oc, nnz;
    ml_operator.Complexities(oc, nnz);
    return oc * nnz;
  }
}

template <typename VectorType>
void DealIIDirectOperator<VectorType>::apply(vector_type const &b,
                                             vector_type &x) const
{
  check_state();
  if (_solver)
    _solver->solve(x, b);
  else
    _smoother->vmult(x, b);
}

template <typename VectorType>
std::shared_ptr<VectorType>
DealIIDirectOperator<VectorType>::build_domain_vector() const
{
  ASSERT_THROW_NOT_IMPLEMENTED();

  return nullptr;
}

template <typename VectorType>
std::shared_ptr<VectorType>
DealIIDirectOperator<VectorType>::build_range_vector() const
{
  ASSERT_THROW_NOT_IMPLEMENTED();

  return nullptr;
}
}

#endif