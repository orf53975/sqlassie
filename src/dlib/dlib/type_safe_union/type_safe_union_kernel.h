// Copyright (C) 2009  Davis E. King (davis@dlib.net)
// License: Boost Software License   See LICENSE.txt for the full license.
#ifndef DLIB_TYPE_SAFE_UNIOn_h_ 
#define DLIB_TYPE_SAFE_UNIOn_h_

#include "type_safe_union_kernel_abstract.h"
#include "../algs.h"
#include "../noncopyable.h"
#include "../serialize.h"
#include <new>

namespace dlib
{

// ----------------------------------------------------------------------------------------

    template <
        typename T1,
        typename T2 = T1,
        typename T3 = T1,
        typename T4 = T1,
        typename T5 = T1, 
        typename T6 = T1,
        typename T7 = T1,
        typename T8 = T1,
        typename T9 = T1,
        typename T10 = T1,

        typename T11 = T1,
        typename T12 = T1,
        typename T13 = T1,
        typename T14 = T1,
        typename T15 = T1,
        typename T16 = T1,
        typename T17 = T1,
        typename T18 = T1,
        typename T19 = T1,
        typename T20 = T1
        >
    class type_safe_union : noncopyable
    {
        /*!
            CONVENTION
                - is_empty() ==  (type_identity == 0)
                - contains<T>() == (type_identity == get_type_id<T>())
                - mem.get() == the block of memory on the stack which is
                  where objects in the union are stored
        !*/

    private:

        const static size_t max_size = tmax<tmax<tmax<tmax<tmax<tmax<tmax<tmax<tmax<tmax<
                                       tmax<tmax<tmax<tmax<tmax<tmax<tmax<tmax<tmax<sizeof(T1),
                                                        sizeof(T2)>::value,
                                                        sizeof(T3)>::value,
                                                        sizeof(T4)>::value,
                                                        sizeof(T5)>::value,
                                                        sizeof(T6)>::value,
                                                        sizeof(T7)>::value,
                                                        sizeof(T8)>::value,
                                                        sizeof(T9)>::value,
                                                        sizeof(T10)>::value,
                                                        sizeof(T11)>::value,
                                                        sizeof(T12)>::value,
                                                        sizeof(T13)>::value,
                                                        sizeof(T14)>::value,
                                                        sizeof(T15)>::value,
                                                        sizeof(T16)>::value,
                                                        sizeof(T17)>::value,
                                                        sizeof(T18)>::value,
                                                        sizeof(T19)>::value,
                                                        sizeof(T20)>::value;

        // --------------------------------------------

        // member data
        stack_based_memory_block<max_size> mem;
        int type_identity;

        // --------------------------------------------


        struct destruct_helper
        {
            template <typename T>
            void operator() (T& item) const
            {
                item.~T();
            }
        };

        void destruct (
        ) 
        /*!
            ensures
                - #is_empty() == true
        !*/
        {
            // destruct whatever is in this object
            apply_to_contents(destruct_helper());

            // mark this object as being empty
            type_identity = 0;
        }

        template <typename T>
        void construct (
        )  
        { 
            if (type_identity != get_type_id<T>())
            {
                destruct(); 
                new(mem.get()) T(); 
                type_identity = get_type_id<T>();
            }
        }

        template <typename T>
        void operator() (T& item) 
        /*
            This function is used by the swap function of this class.  See that
            function to see how this works.
        */
        {
            exchange(get<T>(), item);
        }

    public:

        type_safe_union() : type_identity(0) 
        { 
        }

        ~type_safe_union()
        {
            destruct();
        }

        template <typename T>
        static int get_type_id (
        ) 
        {
            if (is_same_type<T,T1>::value) return 1;
            if (is_same_type<T,T2>::value) return 2;
            if (is_same_type<T,T3>::value) return 3;
            if (is_same_type<T,T4>::value) return 4;
            if (is_same_type<T,T5>::value) return 5;

            if (is_same_type<T,T6>::value) return 6;
            if (is_same_type<T,T7>::value) return 7;
            if (is_same_type<T,T8>::value) return 8;
            if (is_same_type<T,T9>::value) return 9;
            if (is_same_type<T,T10>::value) return 10;

            if (is_same_type<T,T11>::value) return 11;
            if (is_same_type<T,T12>::value) return 12;
            if (is_same_type<T,T13>::value) return 13;
            if (is_same_type<T,T14>::value) return 14;
            if (is_same_type<T,T15>::value) return 15;

            if (is_same_type<T,T16>::value) return 16;
            if (is_same_type<T,T17>::value) return 17;
            if (is_same_type<T,T18>::value) return 18;
            if (is_same_type<T,T19>::value) return 19;
            if (is_same_type<T,T20>::value) return 20;

            // return a number that doesn't match any of the
            // valid states of type_identity
            return -1;
        }

        template <typename T>
        bool contains (
        ) const
        {
            return type_identity == get_type_id<T>();
        }

        bool is_empty (
        ) const
        {
            return type_identity == 0;
        }

    private:
        struct serialize_helper
        {
            /*
                This is a function object to help us serialize type_safe_unions
            */

            std::ostream& out;
            serialize_helper(std::ostream& out_): out(out_) {}
            template <typename T>
            void operator() (const T& item) const { serialize(item, out); } 
        };

    public:

        friend void serialize (
            const type_safe_union& item,
            std::ostream& out
        )
        {
            try
            {
                // save the type_identity
                serialize(item.type_identity, out);
                // Now save whatever it is item contains.  Note that the const cast is ok
                // here since serialize_helper doesn't modify anything in item.  
                const_cast<type_safe_union&>(item).apply_to_contents(serialize_helper(out));
            }
            catch (serialization_error& e)
            {
                throw serialization_error(e.info + "\n   while serializing an object of type type_safe_union");
            }
        }

        friend void deserialize (
            type_safe_union& item,
            std::istream& in
        )
        {
            try
            {
                int type_identity;
                deserialize(type_identity, in);
                switch (type_identity)
                {
                    // swap an empty type_safe_union into item since it should be in the empty state
                    case 0: type_safe_union().swap(item); break;

                    case 1: deserialize(item.get<T1>(), in);  break;
                    case 2: deserialize(item.get<T2>(), in);  break;
                    case 3: deserialize(item.get<T3>(), in);  break;
                    case 4: deserialize(item.get<T4>(), in);  break;
                    case 5: deserialize(item.get<T5>(), in);  break;

                    case 6: deserialize(item.get<T6>(), in);  break;
                    case 7: deserialize(item.get<T7>(), in);  break;
                    case 8: deserialize(item.get<T8>(), in);  break;
                    case 9: deserialize(item.get<T9>(), in);  break;
                    case 10: deserialize(item.get<T10>(), in);  break;

                    case 11: deserialize(item.get<T11>(), in);  break;
                    case 12: deserialize(item.get<T12>(), in);  break;
                    case 13: deserialize(item.get<T13>(), in);  break;
                    case 14: deserialize(item.get<T14>(), in);  break;
                    case 15: deserialize(item.get<T15>(), in);  break;

                    case 16: deserialize(item.get<T16>(), in);  break;
                    case 17: deserialize(item.get<T17>(), in);  break;
                    case 18: deserialize(item.get<T18>(), in);  break;
                    case 19: deserialize(item.get<T19>(), in);  break;
                    case 20: deserialize(item.get<T20>(), in);  break;

                    default: throw serialization_error("Corrupt data detected while deserializing type_safe_union");
                }
            }
            catch (serialization_error& e)
            {
                throw serialization_error(e.info + "\n   while deserializing an object of type type_safe_union");
            }
        }

        template <
            typename T
            >
        void apply_to_contents (
            T& obj
        ) 
        {
            switch (type_identity)
            {
                // do nothing because we are empty
                case 0: break;

                case 1: obj(get<T1>());  break;
                case 2: obj(get<T2>());  break;
                case 3: obj(get<T3>());  break;
                case 4: obj(get<T4>());  break;
                case 5: obj(get<T5>());  break;

                case 6: obj(get<T6>());  break;
                case 7: obj(get<T7>());  break;
                case 8: obj(get<T8>());  break;
                case 9: obj(get<T9>());  break;
                case 10: obj(get<T10>());  break;

                case 11: obj(get<T11>());  break;
                case 12: obj(get<T12>());  break;
                case 13: obj(get<T13>());  break;
                case 14: obj(get<T14>());  break;
                case 15: obj(get<T15>());  break;

                case 16: obj(get<T16>());  break;
                case 17: obj(get<T17>());  break;
                case 18: obj(get<T18>());  break;
                case 19: obj(get<T19>());  break;
                case 20: obj(get<T20>());  break;
            }
        }

        template <
            typename T
            >
        void apply_to_contents (
            const T& obj
        ) 
        {
            switch (type_identity)
            {
                // do nothing because we are empty
                case 0: break;

                case 1: obj(get<T1>());  break;
                case 2: obj(get<T2>());  break;
                case 3: obj(get<T3>());  break;
                case 4: obj(get<T4>());  break;
                case 5: obj(get<T5>());  break;

                case 6: obj(get<T6>());  break;
                case 7: obj(get<T7>());  break;
                case 8: obj(get<T8>());  break;
                case 9: obj(get<T9>());  break;
                case 10: obj(get<T10>());  break;

                case 11: obj(get<T11>());  break;
                case 12: obj(get<T12>());  break;
                case 13: obj(get<T13>());  break;
                case 14: obj(get<T14>());  break;
                case 15: obj(get<T15>());  break;

                case 16: obj(get<T16>());  break;
                case 17: obj(get<T17>());  break;
                case 18: obj(get<T18>());  break;
                case 19: obj(get<T19>());  break;
                case 20: obj(get<T20>());  break;
            }
        }

        void swap (
            type_safe_union& item
        )
        {
            // if both *this and item contain the same type of thing
            if (type_identity == item.type_identity)
            {
                // swap the things in this and item.  
                item.apply_to_contents(*this);
            }
            else if (type_identity == 0)
            {
                // *this doesn't contain anything.  So swap this and item and
                // then destruct item.
                item.apply_to_contents(*this);
                item.destruct();
            }
            else if (item.type_identity == 0)
            {
                // *this doesn't contain anything.  So swap this and item and
                // then destruct this.
                apply_to_contents(item);
                destruct();
            }
            else
            {
                type_safe_union temp;
                // swap *this into temp
                apply_to_contents(temp);
                // swap item into *this
                item.apply_to_contents(*this);
                // swap temp into item
                temp.apply_to_contents(item);
            }
        }

        template <typename T> 
        T& get(
        ) 
        { 
            // ERROR: You are trying to get a type of object that isn't
            // representable by this type_safe_union.  I.e. The given
            // type T isn't one of the ones given to this object's template
            // arguments.
            COMPILE_TIME_ASSERT(( is_same_type<T,T1>::value ||
                                 is_same_type<T,T2>::value ||
                                 is_same_type<T,T3>::value ||
                                 is_same_type<T,T4>::value ||
                                 is_same_type<T,T5>::value ||
                                 is_same_type<T,T6>::value ||
                                 is_same_type<T,T7>::value ||
                                 is_same_type<T,T8>::value ||
                                 is_same_type<T,T9>::value ||
                                 is_same_type<T,T10>::value ||

                                 is_same_type<T,T11>::value ||
                                 is_same_type<T,T12>::value ||
                                 is_same_type<T,T13>::value ||
                                 is_same_type<T,T14>::value ||
                                 is_same_type<T,T15>::value ||
                                 is_same_type<T,T16>::value ||
                                 is_same_type<T,T17>::value ||
                                 is_same_type<T,T18>::value ||
                                 is_same_type<T,T19>::value ||
                                 is_same_type<T,T20>::value 
                                    ));

            construct<T>();  
            return *reinterpret_cast<T*>(mem.get()); 
        }

    };

// ----------------------------------------------------------------------------------------

    template <
        typename T1, typename T2, typename T3, typename T4, typename T5,
        typename T6, typename T7, typename T8, typename T9, typename T10,
        typename T11, typename T12, typename T13, typename T14, typename T15,
        typename T16, typename T17, typename T18, typename T19, typename T20
        >
    inline void swap (
        type_safe_union<T1,T2,T3,T4,T5,T6,T7,T8,T9,T10, T11,T12,T13,T14,T15,T16,T17,T18,T19,T20>& a, 
        type_safe_union<T1,T2,T3,T4,T5,T6,T7,T8,T9,T10, T11,T12,T13,T14,T15,T16,T17,T18,T19,T20>& b 
    ) { a.swap(b); }   

// ----------------------------------------------------------------------------------------

}

#endif // DLIB_TYPE_SAFE_UNIOn_h_

